# Screenshots for `para studio`'s chat: ask the running game window for a picture over the dev
# control channel (the same request `para live shot` makes, through the same client code in
# devclient.nim), take the file the game wrote into the studio's own folder, and serve it back to
# the page from there.
#
# Two rules keep this from ever becoming "read any file on the computer":
#
# - The game names the file it wrote, and the game is only ever as trusted as a program the friend
#   is running; so the name is checked before anything is touched. It has to be a `.png` inside the
#   repository's own `tmp/` folder, a plain file (not a link) that starts with the PNG signature and
#   is not huge. The studio then MOVES it to `tmp/studio/shots/shot-<date>-<time>-<n>.png`, a name
#   the studio makes up itself.
# - The route only ever reads from that one folder, and only a name of exactly that shape
#   (`validShotName`): no path, no extension but `.png`, no way to climb out, so a request cannot
#   name any other file, whatever it contains.
#
# At most `maxShots` pictures are kept; taking one more deletes the oldest. Nothing here talks to
# the network, and nothing is written outside `tmp/`.
#
# Windows: the dev channel there is a loopback port written to `tmp/dev.sock` (paraloop/devsock);
# `devclient` hides the difference, and every path below is joined with `/` and normalised by `os`.

import std/[os, strutils, algorithm, times, atomics]
import agent
import devclient

const
  maxShots* = 20 ## pictures kept; the oldest are deleted past this
  maxShotBytes* = 12 * 1024 * 1024
  pngSignature = "\x89PNG\r\n\x1a\n"
  shotWaitMs = 5000
  shotAskMs = 3000

var shotCounter: Atomic[int]

type
  ShotResult* = object
    ok*: bool
    name*: string ## the studio's own file name when ok
    code*, message*: string ## when not ok: a short stable word and a plain sentence

proc channelPath*(root: string): string =
  ## Where the game's dev channel lives: `tmp/dev.sock` in the folder the studio starts the game in.
  root / "tmp" / "dev.sock"

proc shotsDir*(root: string): string =
  root / "tmp" / "studio" / "shots"

proc validShotName*(name: string): bool =
  ## Exactly `shot-YYYYMMDD-HHMMSS-NNNNNN.png`, digits only (31 characters), so names sort oldest first.
  if name.len != 31 or not name.startsWith("shot-") or not name.endsWith(".png"): return false
  let parts = name[5 ..< name.len - 4].split('-')
  if parts.len != 3: return false
  parts[0].len == 8 and parts[1].len == 6 and parts[2].len == 6 and
    parts[0].allCharsInSet(Digits) and parts[1].allCharsInSet(Digits) and parts[2].allCharsInSet(Digits)

proc newShotName*(): string =
  let n = shotCounter.fetchAdd(1) + 1
  "shot-" & now().utc.format("yyyyMMdd-HHmmss") & "-" & align($(n mod 1_000_000), 6, '0') & ".png"

proc isPlainFile(path: string): bool =
  try:
    getFileInfo(path, followSymlink = false).kind == pcFile
  except OSError:
    false

proc resolveFrame*(root, named: string): string =
  ## The file the game named, as a path inside `<root>/tmp/`, or "" when it names anything else
  ## (another folder, a `..`, a file that is not a `.png`). The name is judged before the file is
  ## looked at.
  let text = named.strip
  if text.len == 0 or text.len > 400 or '\0' in text or '\n' in text or '\r' in text: return ""
  if not text.toLowerAscii.endsWith(".png"): return ""
  let base = (root / "tmp").normalizedPath
  let full = (if text.isAbsolute: text else: root / text).normalizedPath
  if not full.isRelativeTo(base) or cmpPaths(full, base) == 0: return ""
  full

proc readPngSignature(path: string): bool =
  try:
    let f = open(path, fmRead)
    defer: f.close()
    var head = newString(pngSignature.len)
    result = f.readBuffer(addr head[0], head.len) == head.len and head == pngSignature
  except IOError, OSError:
    result = false

proc shotNames*(root: string): seq[string] =
  ## The studio's own pictures, oldest first (the name carries the time).
  let dir = shotsDir(root)
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if kind == pcFile and validShotName(name): result.add name
  result.sort()

proc pruneShots*(root: string, keep = maxShots) =
  let names = shotNames(root)
  if names.len <= keep: return
  for name in names[0 ..< names.len - keep]:
    try: removeFile(shotsDir(root) / name)
    except OSError: discard

proc refuse(code, message: string): ShotResult =
  ShotResult(code: code, message: message)

proc takeShot*(root: string, waitMs = shotWaitMs): ShotResult =
  ## What `para live shot` does (ask the game, wait for the file it names) followed by taking the
  ## picture into the studio's folder. Blocks for as long as the game takes, at most a few seconds.
  let sock = channelPath(root)
  if not socketExists(sock):
    return refuse("no-window", "There is no game window open to take a picture of. Press Play first.")
  var reply: DevReply
  try:
    reply = sendDevRequest(sock, "shot", shotAskMs)
  except IOError:
    return refuse("not-answering", "The game window is not answering. If it is still starting, try again in a moment; if it is stuck, press Stop game and then Play.")
  if not reply.ok:
    return refuse("refused", "The game said it cannot take a picture just now: " & oneLine(redactSecrets(reply.text), 120))
  let frame = resolveFrame(root, reply.text)
  if frame.len == 0:
    return refuse("odd-path", "The game named a picture file in a place the studio does not use, so I left it alone.")
  if not waitForFile(frame, waitMs):
    return refuse("no-picture", "The game window did not produce the picture in time. If the window is hidden or minimised, show it and try again.")
  if not isPlainFile(frame):
    return refuse("odd-path", "The game named something that is not a picture file, so I left it alone.")
  var size = 0'i64
  try: size = getFileSize(frame)
  except OSError: discard
  if size < pngSignature.len or size > maxShotBytes or not readPngSignature(frame):
    return refuse("odd-path", "The file the game named is not a picture the studio can show, so I left it alone.")
  let name = newShotName()
  let dest = shotsDir(root) / name
  var moved = false
  for attempt in 0 ..< 5: # on Windows a virus scanner can hold a new file for a moment
    try:
      createDir(shotsDir(root))
      moveFile(frame, dest)
      moved = true
      break
    except OSError, IOError:
      sleep(100)
  if not moved:
    return refuse("cannot-save", "I could not keep the picture in the game folder's tmp/ folder. Is the disk full, or is something else holding the file?")
  pruneShots(root)
  ShotResult(ok: true, name: name)

proc importPicture*(root, source, allowedDir: string): ShotResult =
  ## A picture an agent made (Codex's image tool saves under its own folder, `allowedDir`) copied
  ## into the studio's folder under a name the studio makes up, so the page can show it. The agent
  ## names the file, so the name is judged first, the way `resolveFrame` does: an absolute `.png`
  ## inside `allowedDir`, a plain file (not a link) that starts with the PNG signature and is not
  ## huge. It is copied, not moved: the file belongs to the agent.
  let text = source # as given: a name with stray whitespace or a newline is not one the agent's tool makes
  if text.len == 0 or text.len > 400 or '\0' in text or '\n' in text or '\r' in text or text != text.strip or
     not text.isAbsolute or not text.toLowerAscii.endsWith(".png") or allowedDir.len == 0:
    return refuse("odd-path", "The producer's tool named a picture in a place the studio does not use, so I left it alone.")
  let base = allowedDir.normalizedPath
  let full = text.normalizedPath
  if not full.isRelativeTo(base) or cmpPaths(full, base) == 0 or not isPlainFile(full):
    return refuse("odd-path", "The producer's tool named a picture in a place the studio does not use, so I left it alone.")
  var size = 0'i64
  try: size = getFileSize(full)
  except OSError: discard
  if size < pngSignature.len or size > maxShotBytes or not readPngSignature(full):
    return refuse("odd-path", "The file the producer's tool named is not a picture the studio can show, so I left it alone.")
  let name = newShotName()
  try:
    createDir(shotsDir(root))
    copyFile(full, shotsDir(root) / name)
  except OSError, IOError:
    return refuse("cannot-save", "I could not keep the picture in the game folder's tmp/ folder. Is the disk full?")
  pruneShots(root)
  ShotResult(ok: true, name: name)

proc readShot*(root, name: string): string =
  ## The bytes of one of the studio's pictures, or "" when the name is not exactly the shape the
  ## studio makes, or the file is not there, is not a plain file or is too big.
  if not validShotName(name): return ""
  let path = shotsDir(root) / name
  if not isPlainFile(path): return ""
  try:
    if getFileSize(path) > maxShotBytes: return ""
    result = readFile(path)
  except IOError, OSError:
    result = ""
