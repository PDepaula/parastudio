# The studio's past chats: every conversation the friend had with one producer about one game.
#
# One small file per game and agent, `tmp/studio/chats-<game>-<agent>.json`, holds that agent's
# chats for the game: each one's number, its title (the start of the first message the friend sent
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
# one lock (the lines go through `ChatFilesStore`, the store behind that runtime). A file the
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

# --- the desk's store ---------------------------------------------------------------

type
  ChatFilesStore* = ref object of Store
    ## The store behind the desk's runtime: a kept line goes to its chat's file, a forgotten chat's
    ## file goes, and every other event (a turn, a step, a pick, a page restore) is not kept on disk.
    root*: string
    stores: Table[string, FileStore]
    checked: Table[string, bool]

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

proc prepare(s: ChatFilesStore) =
  ## Every file an older studio wrote is rewritten in the kit's form (once), so a log read from them is whole.
  for (game, agent, chat) in s.chatFiles:
    if validLog(game, agent, chat): migrateLog(s.root, game, agent, chat)

proc highestSeq*(s: ChatFilesStore): int64 =
  ## The last log position any chat's file holds, so the runtime goes on from there after a restart.
  s.prepare()
  for (game, agent, chat) in s.chatFiles:
    for e in envelopesOf(logPath(s.root, game, agent, chat)): result = max(result, e.seq)

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

method append*(s: ChatFilesStore, evs: openArray[Envelope]) =
  for e in evs:
    try:
      let d = e.data
      case e.kind
      of lineKind:
        if d.intField("n") > 0: s.storeFor(d.strField("game"), d.strField("agent"), int(d.intField("chat"))).append([e])
      of forgetKind:
        s.forgetChat(d.strField("game"), d.strField("agent"), int(d.intField("chat")))
      else: discard
    except CatchableError:
      discard # the disk refused, or the name was not a chat's: the line shows until the studio closes

method load*(s: ChatFilesStore): seq[Envelope] =
  ## Every chat's events, in log order (for a replay).
  s.prepare()
  for (game, agent, chat) in s.chatFiles:
    result.add envelopesOf(logPath(s.root, game, agent, chat))
  result.sort(proc (x, y: Envelope): int = cmp(x.seq, y.seq))

method forget*(s: ChatFilesStore, stream: string) =
  ## `stream` is "<game>/<agent>/<number>".
  let p = stream.split('/')
  if p.len != 3 or not p[2].allCharsInSet(Digits) or p[2].len == 0 or p[2].len > 9:
    raise newException(ValueError, "forget: not a chat's stream")
  s.forgetChat(p[0], p[1], parseInt(p[2]))

method close*(s: ChatFilesStore) =
  for fs in s.stores.values: fs.close
  s.stores.clear()
