# The studio's past chats: every conversation the friend had with one producer about one game.
#
# Where the chats' books live now: they are events (studiodesk.nim's `ChatBook` view), kept with the
# producer and speed picks and what each producer last ran with in ONE studio-wide file,
# `tmp/studio/studio.jsonl`, the kit's forgetting file store (see "the studio's own events" below). The
# files older studios kept, `chats-<game>-<agent>.json`, `session-*.id`, `agent-<game>.txt`,
# `speed-<game>.txt` and `default-agent.txt`, are read once, written as events and removed (the
# `old...` procs below and the shell's migration); this file still reads them, and can still write a
# book file, which no studio does any more.
#
# What a book file holds (the same facts the events carry): `tmp/studio/chats-<game>-<agent>.json`
# held that agent's chats for the game: each one's number, its title (the start of the first message the friend sent
# in it, on one line, at most `maxTitleRunes` letters, with anything that looks like a key taken
# out), when it started and was last used, and the agent's session id once the agent reported one,
# so opening an old chat resumes the same conversation. Which chat the next message goes to is
# kept too (`current`); a fresh chat has a number but no entry until its first message, so an
# empty chat is never listed.
#
# Each chat's lines, as the page showed them, are kept beside it in
# `tmp/studio/chat-<game>-<agent>-<number>.jsonl`, one line of JSON each (an event of the kit's
# forgetting file store, see "each chat's lines" below): what the friend typed,
# what the producer said, its activity lines, helper cards (where they started and how they ended,
# not every step in between), notes, errors and picture cards. Text is kept as it was with anything
# that looks like a key taken out (the same `redactSecrets` as the titles), and one message is cut
# past `maxLineText` bytes. A chat's file is kept under `maxLogBytes`: past that its oldest lines
# are left out, down to `keepLogBytes`, behind a note that says so. These files stay on this
# computer, in the repository's `tmp/` folder (never tracked, never part of a save point), are
# never uploaded, and go when the chat is deleted. No login or key is ever kept.
#
# Before there was a list, the studio kept one session id per game and agent in
# `session-<game>-<agent>.id` (and, before there was a second agent, Claude's in `session-<game>.id`).
# Such a file is read as one chat with no title, and removed once the new file is written.
#
# This file only reads and writes; studiochat.nim decides when, with the desk's runtime under its
# one lock (the lines and the studio's events go through `ChatFilesStore`, the store behind that runtime). A file the
# studio did not write the way it writes it (not JSON, a field of the wrong kind, a session id that
# could not be one) is read as far as it makes sense and the rest is left out; it never raises.

import std/[algorithm, json, os, sequtils, strutils, tables, times]
from std/unicode import runeLen, runeSubStr, validateUtf8
import eversince/[types, store, store_file]
import agent
import savepoint

const
  maxTitleRunes* = 60
  maxChatId = 999_999_999
  maxLineText* = 16_000 ## bytes kept of one message; the rest is cut
  maxLogBytes* = 512 * 1024 ## one chat's kept lines; past this the oldest are left out...
  keepLogBytes* = 384 * 1024 ## ...down to this

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

# --- each chat's lines ------------------------------------------------------------

const kindWords: array[UiKind, string] = ["say", "activity", "helper", "refused", "notice", "error", "done", "shot"]

proc logPath*(root, game, agent: string, chat: int): string =
  studioDir(root) / ("chat-" & game & "-" & agent & "-" & $chat & ".jsonl")

proc validLog(game, agent: string, chat: int): bool =
  validGameName(game) and validAgentName(agent) and chat in 1..maxChatId

proc keptText*(text: string): string =
  ## `text` as a chat's file keeps it: keys taken out, and cut past `maxLineText` bytes (on a
  ## letter, not inside one) with a few words saying so.
  result = redactSecrets(text)
  if result.len > maxLineText:
    var cut = maxLineText
    while cut > 0 and (ord(result[cut]) and 0xC0) == 0x80: dec cut
    result = result[0 ..< cut].strip(leading = false) & "… (the rest of this message was too long to keep)"

proc encodeLine(line: ChatLine): string =
  let ev = line.ev
  let n = %*{"kind": (if line.you: "you" else: kindWords[ev.kind]), "text": keptText(ev.text)}
  case ev.kind
  of ukHelper:
    n["id"] = %oneLine(ev.id, 100)
    n["role"] = %oneLine(ev.role, 20)
    n["status"] = %oneLine(ev.status, 20)
    n["tools"] = %ev.tools
  of ukNotice, ukError, ukRefused:
    if ev.code.len > 0: n["code"] = %oneLine(ev.code, 40)
    if ev.detail.len > 0: n["detail"] = %keptText(ev.detail)
    if ev.kind != ukRefused and ev.url.startsWith("https://"): n["url"] = %ev.url
  else: discard
  $n

proc strField(n: JsonNode, key: string): string =
  let v = n{key}
  if v != nil and v.kind == JString: v.getStr else: ""

proc decodeLine(text: string, line: var ChatLine): bool =
  ## One kept line back as the page shows it; false for a line the studio did not write.
  var n: JsonNode
  try: n = parseJson(text)
  except CatchableError: return false
  if n.kind != JObject: return false
  let word = n.strField("kind")
  var kind = ukSay
  if word != "you":
    var known = false
    for k in UiKind:
      if kindWords[k] == word and k != ukTurnDone:
        kind = k
        known = true
    if not known: return false
  let url = n.strField("url")
  line = (you: word == "you", ev: UiEvent(kind: kind, text: n.strField("text"), id: n.strField("id"),
    role: n.strField("role"), status: n.strField("status"), tools: int(n.intField("tools").clamp(-1, 1_000_000)),
    code: n.strField("code"), detail: n.strField("detail"),
    url: if kind in {ukNotice, ukError} and url.startsWith("https://"): url else: ""))
  true

proc asKept*(line: ChatLine): ChatLine =
  ## `line` as its chat's file keeps it and gives it back.
  discard decodeLine(encodeLine(line), result)

# The lines are the kit's own (eversince, a pinned nimble dependency): each chat's file is a
# forgetting file store (`openFileStore`), one JSON line per event {"seq","at","kind","data"}, and
# its three duties are the store's hooks and not code of ours:
#   clean     every line is written with keys taken out and long text cut (`keptBody`)
#   cap       the file keeps the newest lines under `maxLogBytes` (`maxStreamBytes`; the oldest go first)
#   forget    the chat's lines are taken out of the file when the chat is deleted (`dropLines`)
# The chat's own lines are the desk's `LineAdded` events (studiodesk.nim); `ChatFilesStore` is the
# store the desk's runtime writes them to. A file an older studio wrote (one compact line each,
# `{"kind": "say", "text": ...}`) is read as before and rewritten in the kit's form the first time
# the studio opens it.

const
  lineKind* = "LineAdded" ## the kind of the desk event that carries a kept line
  forgetKind* = "ChatForgotten" ## the kind of the desk event that takes a chat out of its file

proc studioFiles(root: string): string = studioDir(root)

proc streamKey(game, agent: string, chat: int): string = game & "/" & agent & "/" & $chat

proc nowMs(): int64 = (epochTime() * 1000).int64

proc lineBody*(line: ChatLine): JsonNode =
  ## A line as the desk's `LineBody` holds it: every field, as it is.
  let ev = line.ev
  %*{"you": line.you, "kind": kindWords[ev.kind], "text": ev.text, "id": ev.id, "role": ev.role,
     "status": ev.status, "tools": ev.tools, "code": ev.code, "detail": ev.detail, "url": ev.url}

proc lineOfBody*(n: JsonNode, line: var ChatLine, allowDone = false): bool =
  ## A `LineBody` back as the page shows it; false for one that is not a line the studio writes
  ## (the end-of-turn marker only when `allowDone`).
  if n == nil or n.kind != JObject: return false
  let word = n.strField("kind")
  var kind = ukSay
  var known = false
  for k in UiKind:
    if kindWords[k] == word and (allowDone or k != ukTurnDone):
      kind = k
      known = true
  if not known: return false
  let url = n.strField("url")
  let you = n{"you"}
  line = (you: you != nil and you.kind == JBool and you.getBool, ev: UiEvent(kind: kind, text: n.strField("text"), id: n.strField("id"),
    role: n.strField("role"), status: n.strField("status"), tools: int(n.intField("tools").clamp(-1, 1_000_000)),
    code: n.strField("code"), detail: n.strField("detail"),
    url: if kind in {ukNotice, ukError} and url.startsWith("https://"): url else: ""))
  true

proc lineData*(game, agent: string, chat, n: int, line: ChatLine): JsonNode =
  ## The data of a `LineAdded` event.
  %*{"game": game, "agent": agent, "chat": chat, "n": n, "line": lineBody(line)}

proc keptBody(body: JsonNode): JsonNode =
  var line: ChatLine
  if lineOfBody(body, line): lineBody(asKept(line)) else: body

proc cleanEnvelope(e: Envelope): Envelope =
  ## The store's clean hook: a line is written with keys taken out, long text cut and a link kept
  ## only when it is https. The views of the running studio saw the line as it was.
  result = e
  if e.kind == lineKind and e.data != nil and e.data.kind == JObject and e.data.hasKey("line"):
    var data = newJObject()
    for k, v in e.data: data[k] = v
    data["line"] = keptBody(e.data["line"])
    result.data = data

proc streamOfEnvelope(e: Envelope): string =
  let d = e.data
  if d == nil or d.kind != JObject: return ""
  streamKey(d.strField("game"), d.strField("agent"), int(d.intField("chat")))

proc openChatStore(path: string): FileStore =
  createDir(path.parentDir)
  openFileStore(path, clean = cleanEnvelope, streamOf = streamOfEnvelope, maxStreamBytes = maxLogBytes)

proc isEnvelope(n: JsonNode): bool =
  n.kind == JObject and n{"seq"} != nil and n["seq"].kind == JInt and n{"kind"} != nil and n["kind"].kind == JString and
    n{"data"} != nil and n["data"].kind == JObject

proc writeWhole(path: string, lines: seq[string]): bool =
  try:
    createDir(path.parentDir)
    writeFile(path & ".new", (if lines.len > 0: lines.join("\n") & "\n" else: ""))
    moveFile(path & ".new", path)
    true
  except IOError, OSError:
    false

proc migrateLog(root, game, agent: string, chat: int) =
  ## A file an older studio wrote is rewritten in the kit's form, once. Lines it could not read are left out.
  let path = logPath(root, game, agent, chat)
  var text: string
  try: text = readFile(path)
  except IOError, OSError: return
  var legacy = false
  for raw in text.splitLines:
    if raw.len == 0: continue
    try:
      if not isEnvelope(parseJson(raw)): legacy = true
    except CatchableError: legacy = true
  if not legacy: return
  var rows: seq[string]
  var seqNo = 0'i64
  var num = 0
  let at = try: getLastModificationTime(path).toUnix * 1000 except OSError: nowMs()
  for raw in text.splitLines:
    if raw.len == 0: continue
    var n: JsonNode
    try: n = parseJson(raw)
    except CatchableError: continue
    if isEnvelope(n):
      seqNo = max(seqNo, n["seq"].getBiggestInt)
      num = max(num, int(n["data"].intField("n")))
      rows.add raw
    else:
      var line: ChatLine
      if decodeLine(raw, line):
        inc seqNo
        inc num
        rows.add toLine(Envelope(seq: seqNo, at: at, kind: lineKind, data: lineData(game, agent, chat, num, line)))
  discard writeWhole(path, rows)

type
  ChatRead* = object
    found*: bool            ## false when the chat has no file
    lines*: seq[ChatLine]
    lastN*: int             ## the number of the last kept line, which the desk goes on counting from

proc trimNoteLine(): ChatLine =
  (you: false, ev: UiEvent(kind: ukNotice, code: "chat-trimmed",
    text: "The oldest part of this chat was left out to keep it small (each chat keeps about its last 500 KB of messages)."))

proc readChat*(root, game, agent: string, chat: int): ChatRead =
  ## Chat `chat`'s kept lines, in either form (the kit's, or an older studio's). A file that cannot
  ## be read gives no lines; a line the studio did not write is left out. When the file's first line
  ## is not the chat's first (the cap took the oldest), one note says so, in front.
  if not validLog(game, agent, chat): return
  let path = logPath(root, game, agent, chat)
  if not fileExists(path): return
  result.found = true
  var text: string
  try: text = readFile(path)
  except IOError, OSError: return
  var trimmed = false
  var first = true
  for raw in text.splitLines:
    if raw.len == 0: continue
    var n: JsonNode
    try: n = parseJson(raw)
    except CatchableError: continue
    var line: ChatLine
    if n.kind != JObject: continue
    if isEnvelope(n):
      if n["kind"].getStr != lineKind or not lineOfBody(n["data"]{"line"}, line): continue
      let num = int(n["data"].intField("n"))
      if first: trimmed = num > 1
      first = false
      result.lastN = num
      result.lines.add line
    elif decodeLine(raw, line):
      first = false
      inc result.lastN
      result.lines.add line
  if trimmed:
    result.lines = @[trimNoteLine()] & result.lines.filterIt(it.ev.code != "chat-trimmed")

proc readLines*(root, game, agent: string, chat: int): tuple[found: bool, lines: seq[ChatLine]] =
  ## Chat `chat`'s kept lines. `found` is false when it has no file: a chat from before lines were
  ## kept, or one with no line yet.
  let r = readChat(root, game, agent, chat)
  (r.found, r.lines)

proc lastOf(log: seq[Envelope]): tuple[seqNo: int64, num: int] =
  for i in countdown(log.high, 0):
    if result.seqNo == 0: result.seqNo = log[i].seq
    if log[i].kind == lineKind:
      result.num = int(log[i].data.intField("n"))
      return

proc appendLine*(root, game, agent: string, chat: int, line: ChatLine): bool =
  ## Adds one line to chat `chat`'s file, through the file store; false when it could not be written
  ## (the line still shows while the studio runs). The studio's own lines go through the desk's
  ## runtime and `ChatFilesStore`; this is the same write for a caller that has no runtime.
  if not validLog(game, agent, chat): return false
  try:
    createDir(studioFiles(root))
    migrateLog(root, game, agent, chat)
    let fs = openChatStore(logPath(root, game, agent, chat))
    defer: fs.close
    let (seqNo, num) = lastOf(fs.load)
    fs.append([Envelope(seq: seqNo + 1, at: nowMs(), kind: lineKind, data: lineData(game, agent, chat, num + 1, line))])
    true
  except CatchableError:
    false

proc dropLines*(root, game, agent: string, chat: int) =
  ## Forgets chat `chat`'s lines: the store takes its stream out of the file, and a file with nothing
  ## else in it goes. Does nothing for a chat with no file.
  if not validLog(game, agent, chat): return
  let path = logPath(root, game, agent, chat)
  if not fileExists(path): return
  try:
    migrateLog(root, game, agent, chat)
    let fs = openChatStore(path)
    try: fs.forget(streamKey(game, agent, chat))
    finally: fs.close
  except CatchableError:
    discard
  try: removeFile(path)
  except OSError: discard

# --- the studio's own events ---------------------------------------------------------

const
  studioKinds = ["ChatStarted", "ChatOpened", "ChatUsed", "SessionReported", "AgentPicked", "SpeedPicked", "ModelReported"]
  maxStudioStreamBytes = 64 * 1024 ## one stream of studio.jsonl; only what a producer last ran with ever grows

proc studioPath*(root: string): string = studioDir(root) / "studio.jsonl"

proc studioStreamOf(e: Envelope): string =
  ## The chat-scoped events belong to the chat's stream (so forgetting the chat takes them out of this
  ## file too), what a producer ran with to a stream of its own (capped), the picks to none.
  let d = e.data
  if d == nil or d.kind != JObject: return ""
  case e.kind
  of "ChatStarted", "ChatOpened", "ChatUsed", "SessionReported":
    streamKey(d.strField("game"), d.strField("agent"), int(d.intField("chat")))
  of "ModelReported": "ran:" & d.strField("game") & "/" & d.strField("agent")
  else: ""

proc cleanStudio(e: Envelope): Envelope =
  ## The store's clean hook for studio.jsonl: a session id is written only in the shape
  ## `validSessionToken` accepts, and a title with keys taken out.
  result = e
  if e.data == nil or e.data.kind != JObject: return
  var data = newJObject()
  for k, v in e.data: data[k] = v
  case e.kind
  of "SessionReported": data["session"] = %validSessionToken(e.data.strField("session"))
  of "ChatUsed": data["title"] = %redactSecrets(e.data.strField("title"))
  else: return
  result.data = data

# --- the desk's store ---------------------------------------------------------------

type
  ChatFilesStore* = ref object of Store
    ## The store behind the desk's runtime: a kept line goes to its chat's file, the studio's own
    ## events (a chat's book, a pick, what a producer ran with) to studio.jsonl, a forgotten chat's
    ## file and events go, and every other event (a turn, a step, a page restore) is not kept on disk.
    root*: string
    stores: Table[string, FileStore]
    checked: Table[string, bool]
    studio: FileStore
    parked: seq[FileStore] ## closed stores, kept alive (see `close`)
    failed*: bool ## a write was refused since the shell last cleared this (the disk is full or read-only)

proc newChatFiles*(root: string): ChatFilesStore =
  ChatFilesStore(root: root)

proc chatFiles(s: ChatFilesStore): seq[tuple[game, agent: string, chat: int]] =
  ## The chats that have a file: `chat-<game>-<agent>-<number>.jsonl`. A game's name has no `-`.
  let dir = studioDir(s.root)
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if not (name.startsWith("chat-") and name.endsWith(".jsonl")): continue
    let core = name[5 ..< name.len - 6]
    let a = core.find('-')
    let b = core.rfind('-')
    if a < 1 or b <= a: continue
    let num = core[b + 1 .. ^1]
    if num.len == 0 or not num.allCharsInSet(Digits) or num.len > 9: continue
    result.add (core[0 ..< a], core[a + 1 ..< b], parseInt(num))

proc envelopesOf(path: string): seq[Envelope] =
  ## The events of one file; a line that is not an event is skipped.
  var text: string
  try: text = readFile(path)
  except IOError, OSError: return
  for raw in text.splitLines:
    if raw.len == 0: continue
    try:
      let n = parseJson(raw)
      if isEnvelope(n): result.add fromLine(raw)
    except CatchableError: discard

proc loadStudio*(s: ChatFilesStore): seq[Envelope] =
  ## The studio's own events, in log order: the only thing the shell replays when it starts. A line
  ## that is not an event is skipped, so a file edited by hand never stops the studio.
  result = envelopesOf(studioPath(s.root))
  result.sort(proc (x, y: Envelope): int = cmp(x.seq, y.seq))

proc tidyStudio(path: string) =
  ## studio.jsonl as the store wants it: a line that is not an event is left out (the store refuses
  ## to open a log with one in the middle, and the studio would then keep nothing).
  var text: string
  try: text = readFile(path)
  except IOError, OSError: return
  var rows: seq[string]
  var dropped = false
  for raw in text.splitLines:
    if raw.len == 0: continue
    try:
      if isEnvelope(parseJson(raw)): rows.add raw
      else: dropped = true
    except CatchableError: dropped = true
  if dropped: discard writeWhole(path, rows)

proc studioStore(s: ChatFilesStore): FileStore =
  if s.studio == nil:
    let path = studioPath(s.root)
    createDir(path.parentDir)
    tidyStudio(path)
    s.studio = openFileStore(path, clean = cleanStudio, streamOf = studioStreamOf, maxStreamBytes = maxStudioStreamBytes)
  s.studio

proc forgetStudio(s: ChatFilesStore, stream: string) =
  ## The chat's events leave studio.jsonl (its session id with them).
  if s.studio == nil and not fileExists(studioPath(s.root)): return
  s.studioStore.forget(stream)

proc prepare(s: ChatFilesStore) =
  ## Every file an older studio wrote is rewritten in the kit's form (once), so a log read from them is whole.
  for (game, agent, chat) in s.chatFiles:
    if validLog(game, agent, chat): migrateLog(s.root, game, agent, chat)

proc highestSeq*(s: ChatFilesStore): int64 =
  ## The last log position any file holds, so the runtime goes on from there after a restart.
  s.prepare()
  for (game, agent, chat) in s.chatFiles:
    for e in envelopesOf(logPath(s.root, game, agent, chat)): result = max(result, e.seq)
  for e in envelopesOf(studioPath(s.root)): result = max(result, e.seq)

proc storeFor(s: ChatFilesStore, game, agent: string, chat: int): FileStore =
  if not validLog(game, agent, chat): raise newException(ValueError, "not a chat the studio keeps")
  let path = logPath(s.root, game, agent, chat)
  if path notin s.stores:
    if path notin s.checked:
      migrateLog(s.root, game, agent, chat)
      s.checked[path] = true
    s.stores[path] = openChatStore(path)
  s.stores[path]

proc forgetChat(s: ChatFilesStore, game, agent: string, chat: int) =
  let path = logPath(s.root, game, agent, chat)
  if path in s.stores:
    s.stores[path].close
    s.stores.del(path)
  s.checked.del(path)
  dropLines(s.root, game, agent, chat)
  if validLog(game, agent, chat):
    try: s.forgetStudio(streamKey(game, agent, chat))
    except CatchableError: discard # the lines are gone; the studio's own events of it go with the next rewrite

method append*(s: ChatFilesStore, evs: openArray[Envelope]) =
  for e in evs:
    try:
      let d = e.data
      case e.kind
      of lineKind:
        if d.intField("n") > 0: s.storeFor(d.strField("game"), d.strField("agent"), int(d.intField("chat"))).append([e])
      of forgetKind:
        s.forgetChat(d.strField("game"), d.strField("agent"), int(d.intField("chat")))
      elif e.kind in studioKinds:
        s.studioStore.append([e])
      else: discard
    except CatchableError:
      s.failed = true # the disk refused, or the name was not a chat's: the line shows until the studio closes

method load*(s: ChatFilesStore): seq[Envelope] =
  ## Every chat's events and the studio's own, in log order (for a replay).
  s.prepare()
  for (game, agent, chat) in s.chatFiles:
    result.add envelopesOf(logPath(s.root, game, agent, chat))
  result.add envelopesOf(studioPath(s.root))
  result.sort(proc (x, y: Envelope): int = cmp(x.seq, y.seq))

method forget*(s: ChatFilesStore, stream: string) =
  ## `stream` is "<game>/<agent>/<number>".
  let p = stream.split('/')
  if p.len != 3 or not p[2].allCharsInSet(Digits) or p[2].len == 0 or p[2].len > 9:
    raise newException(ValueError, "forget: not a chat's stream")
  s.forgetChat(p[0], p[1], parseInt(p[2]))

method close*(s: ChatFilesStore) =
  ## Lets go of every file. A closed store is parked, not freed: the stores are made on whichever
  ## thread wrote first (a turn's, a request's), and an ORC reference must not be freed on another
  ## thread than the one that made it. A later write opens the file again.
  for fs in s.stores.values:
    fs.close
    s.parked.add fs
  s.stores.clear()
  if s.studio != nil:
    s.studio.close
    s.parked.add s.studio
    s.studio = nil

# --- what older studios kept: read once, then written as events and removed ----------------

type
  OldPicks* = object
    ## The files that held the producer and speed picks, as they were (nothing checked yet).
    wide*: string                       ## default-agent.txt, "" when there is none
    agents*: seq[tuple[game, name: string]]  ## agent-<game>.txt
    speeds*: seq[tuple[game, name: string]]  ## speed-<game>.txt

proc fileText(path: string): string =
  try: readFile(path).strip
  except IOError, OSError: ""

proc oldBooks*(root: string): seq[tuple[game, agent: string]] =
  ## The games and agents that have a book file or a session file of an older studio, in name order.
  let dir = studioDir(root)
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    var core = ""
    if name.startsWith("chats-") and name.endsWith(".json"): core = name[6 ..< name.len - 5]
    elif name.startsWith("session-") and name.endsWith(".id"): core = name[8 ..< name.len - 3]
    else: continue
    let at = core.find('-')
    let pair = if at < 0: (core, "claude") else: (core[0 ..< at], core[at + 1 .. ^1]) # session-<game>.id was Claude's
    if validGameName(pair[0]) and validAgentName(pair[1]) and pair notin result: result.add pair
  result.sort(proc (x, y: tuple[game, agent: string]): int = cmp(x.game & "/" & x.agent, y.game & "/" & y.agent))

proc hasOldBook*(root, game, agent: string): bool =
  fileExists(chatsPath(root, game, agent)) or legacyPaths(root, game, agent).anyIt(fileExists(it))

proc removeOldBook*(root, game, agent: string) =
  ## The older studio's files for this book go, once the events hold what they did.
  for path in @[chatsPath(root, game, agent)] & legacyPaths(root, game, agent):
    try: removeFile(path)
    except OSError: discard

proc oldBookEvents*(game, agent: string, b: ChatBook, now: int64): seq[tuple[kind: string, data: JsonNode]] =
  ## A book as the events that make the `ChatBook` view hold it again: each chat used (at its start,
  ## and at its last use when that is later), its session, then the chat the next message goes to.
  for c in b.chats:
    result.add ("ChatUsed", %*{"game": game, "agent": agent, "chat": c.id, "at": c.started, "title": c.title})
    if c.updated != c.started:
      result.add ("ChatUsed", %*{"game": game, "agent": agent, "chat": c.id, "at": c.updated, "title": c.title})
    if c.session.len > 0:
      result.add ("SessionReported", %*{"game": game, "agent": agent, "chat": c.id, "session": c.session})
  if b.find(b.current) >= 0:
    result.add ("ChatOpened", %*{"game": game, "agent": agent, "chat": b.current, "next": b.next})
  elif b.chats.len > 0 or b.current > 1:
    result.add ("ChatStarted", %*{"game": game, "agent": agent, "chat": b.current, "at": now})

proc oldPicks*(root: string): OldPicks =
  let dir = studioDir(root)
  if not dirExists(dir): return
  result.wide = fileText(dir / "default-agent.txt")
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if name.startsWith("agent-") and name.endsWith(".txt"):
      result.agents.add (name[6 ..< name.len - 4], fileText(path))
    elif name.startsWith("speed-") and name.endsWith(".txt"):
      result.speeds.add (name[6 ..< name.len - 4], fileText(path))
  result.agents.sort(proc (x, y: tuple[game, name: string]): int = cmp(x.game, y.game))
  result.speeds.sort(proc (x, y: tuple[game, name: string]): int = cmp(x.game, y.game))

proc removeOldPicks*(root: string) =
  let dir = studioDir(root)
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if name == "default-agent.txt" or (name.startsWith("agent-") and name.endsWith(".txt")) or
        (name.startsWith("speed-") and name.endsWith(".txt")):
      try: removeFile(path)
      except OSError: discard
