# The studio's past chats: every conversation the friend had with one producer about one game.
#
# One small file per game and agent, `tmp/studio/chats-<game>-<agent>.json`, holds that agent's
# chats for the game: each one's number, its title (the start of the first message the friend sent
# in it, on one line, at most `maxTitleRunes` letters, with anything that looks like a key taken
# out), when it started and was last used, and the agent's session id once the agent reported one,
# so opening an old chat resumes the same conversation. Which chat the next message goes to is
# kept too (`current`); a fresh chat has a number but no entry until its first message, so an
# empty chat is never listed. Nothing else is kept: not the rest of what the friend typed, not
# what the producer said, and no login or key.
#
# Before there was a list, the studio kept one session id per game and agent in
# `session-<game>-<agent>.id` (and, before there was a second agent, Claude's in `session-<game>.id`).
# Such a file is read as one chat with no title, and removed once the new file is written.
#
# This file only reads and writes; studiochat.nim decides when, under its own lock. A file the
# studio did not write the way it writes it (not JSON, a field of the wrong kind, a session id that
# could not be one) is read as far as it makes sense and the rest is left out; it never raises.

import std/[algorithm, json, os, strutils, times]
from std/unicode import runeLen, runeSubStr, validateUtf8
import agent
import savepoint

const
  maxTitleRunes* = 60
  maxChatId = 999_999_999

type
  ChatRecord* = object
    id*: int
    title*: string      ## "" for a chat from before there were titles
    started*, updated*: int64 ## seconds since 1970
    session*: string    ## the agent's own id for the conversation, "" until it reports one

  ChatBook* = object
    ## One game and agent's chats.
    current*: int       ## the chat the next message goes to (it may have no record yet: a fresh chat)
    next*: int          ## the number the next fresh chat gets; numbers are never reused
    chats*: seq[ChatRecord] ## the one used last at the end

proc validAgentName*(agent: string): bool =
  agent.len in 1..24 and agent.allCharsInSet({'a'..'z', '0'..'9', '-'})

proc studioDir(root: string): string = root / "tmp" / "studio"

proc chatsPath*(root, game, agent: string): string =
  studioDir(root) / ("chats-" & game & "-" & agent & ".json")

proc legacyPaths(root, game, agent: string): seq[string] =
  result = @[studioDir(root) / ("session-" & game & "-" & agent & ".id")]
  if agent == "claude": result.add studioDir(root) / ("session-" & game & ".id")

proc titleOf*(text: string): string =
  ## A chat's title from the first message sent in it: one line, keys taken out, at most
  ## `maxTitleRunes` letters (cut with an ellipsis).
  let line = oneLine(redactSecrets(text), int.high)
  if validateUtf8(line) != -1: return ""
  if line.runeLen <= maxTitleRunes: line
  else: line.runeSubStr(0, maxTitleRunes).strip(leading = false) & "…"

proc freshBook(): ChatBook = ChatBook(current: 1, next: 2)

proc find*(b: ChatBook, id: int): int =
  ## The index of chat `id` in `b.chats`, -1 when there is none.
  for i, c in b.chats:
    if c.id == id: return i
  -1

proc settle(b: var ChatBook) =
  ## `next` past every number in use, and a `current` that is a number.
  b.next = max(b.next, 1)
  for c in b.chats: b.next = max(b.next, c.id + 1)
  if b.current < 1 or b.current > maxChatId: b.current = b.next
  b.next = max(b.next, b.current + 1)

proc intField(n: JsonNode, key: string): int64 =
  let v = n{key}
  if v != nil and v.kind == JInt: v.getBiggestInt else: 0

proc parseBook(text: string): ChatBook =
  result = freshBook()
  var root: JsonNode
  try: root = parseJson(text)
  except CatchableError: return
  if root.kind != JObject: return
  result.current = int(root.intField("current").clamp(0, maxChatId))
  result.next = int(root.intField("next").clamp(0, maxChatId))
  let list = root{"chats"}
  if list != nil and list.kind == JArray:
    for n in list:
      if n.kind != JObject: continue
      let id = n.intField("id")
      if id < 1 or id > maxChatId or result.find(int(id)) >= 0: continue
      let title = n{"title"}
      let session = n{"session"}
      result.chats.add ChatRecord(id: int(id),
        title: if title != nil and title.kind == JString: titleOf(title.getStr) else: "",
        started: n.intField("started"), updated: n.intField("updated"),
        session: if session != nil and session.kind == JString: validSessionToken(session.getStr) else: "")
  result.settle()

proc legacyBook(root, game, agent: string): ChatBook =
  ## The one conversation an older studio kept, as one chat; a fresh book when there is none.
  result = freshBook()
  for path in legacyPaths(root, game, agent):
    try:
      let id = validSessionToken(readFile(path).strip)
      if id.len == 0: continue
      let at = getLastModificationTime(path).toUnix
      result.chats.add ChatRecord(id: 1, started: at, updated: at, session: id)
      return
    except IOError, OSError:
      discard

proc loadBook*(root, game, agent: string): ChatBook =
  ## `game`'s chats with `agent`. A fresh book (one empty chat, nothing listed) when there are none
  ## or the names are not ones the studio makes.
  if not validGameName(game) or not validAgentName(agent): return freshBook()
  let path = chatsPath(root, game, agent)
  var text: string
  try: text = readFile(path)
  except IOError, OSError: return legacyBook(root, game, agent)
  parseBook(text)

proc toJson(b: ChatBook): JsonNode =
  var list = newJArray()
  for c in b.chats:
    list.add %*{"id": c.id, "title": c.title, "started": c.started, "updated": c.updated, "session": c.session}
  %*{"current": b.current, "next": b.next, "chats": list}

proc saveBook*(root, game, agent: string, b: ChatBook): bool =
  ## Writes the book in one step (a new file moved over the old one); false when it could not be
  ## written, and then the chats still work but are forgotten when the studio closes.
  if not validGameName(game) or not validAgentName(agent): return false
  let path = chatsPath(root, game, agent)
  try:
    createDir(path.parentDir)
    writeFile(path & ".new", $b.toJson & "\n")
    moveFile(path & ".new", path)
  except IOError, OSError:
    return false
  for old in legacyPaths(root, game, agent): # the new file now holds what they did
    try: removeFile(old)
    except OSError: discard
  true

proc newestFirst*(b: ChatBook): seq[ChatRecord] =
  ## The chats to list, the one used last first (two used in the same second: the later one).
  result = b.chats.reversed
  result.sort(proc (x, y: ChatRecord): int = cmp(y.updated, x.updated)) # a stable sort

proc noteMessage*(b: var ChatBook, text: string, now: int64): string =
  ## A message is being sent in the current chat: gives a fresh chat its title from it, marks the
  ## chat as used now, and returns the session id to resume ("" for a new conversation).
  let i = b.find(b.current)
  if i < 0:
    b.chats.add ChatRecord(id: b.current, title: titleOf(text), started: now, updated: now)
    b.settle()
    return ""
  var c = b.chats[i]
  b.chats.delete(i)
  c.updated = now
  b.chats.add c # the one used last goes at the end
  c.session

proc setSession*(b: var ChatBook, id: int, session: string): bool =
  ## Chat `id`'s conversation is `session` from now on; false when there is no such chat or the
  ## id could not be one.
  let i = b.find(id)
  let token = validSessionToken(session)
  if i < 0 or token.len == 0: return false
  b.chats[i].session = token
  true

proc freshChat*(b: var ChatBook) =
  ## The next message starts a new conversation. Nothing changes when the current chat is already
  ## a fresh one (no message sent in it yet).
  if b.find(b.current) < 0: return
  b.current = b.next
  inc b.next

proc openChat*(b: var ChatBook, id: int): bool =
  ## The next message goes to chat `id`; false when there is no such chat.
  if b.find(id) < 0: return false
  b.current = id
  true

proc dropChat*(b: var ChatBook, id: int): bool =
  ## Forgets chat `id`; when it was the current one, the next message starts a fresh chat. False
  ## when there is no such chat.
  let i = b.find(id)
  if i < 0: return false
  b.chats.delete(i)
  if b.current == id:
    b.current = b.next
    inc b.next
  true
