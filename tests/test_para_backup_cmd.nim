# Tests for `para backup`, driven on scratch git repos with bare local
# repositories standing in for the friend's online one and for the paraloop
# upstream, and a fake `gh` script for the privacy answer. No network. The
# rules under test: it uploads only to the remote named `backup`, only when
# the friend said yes and the repository is private, never to origin or the
# Para Studio project, never with force.

import std/[unittest, os, strutils, sequtils, tempfiles, algorithm]
import tools/para/nimutil
import tools/para/art/clihelpers
import tools/para/backupcmd

proc gitOk(root: string, args: varargs[string]): string =
  let r = runCaptured("git", @args, root)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

proc put(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc newBare(): string =
  result = createTempDir("para_backup_bare_", "")
  discard gitOk(result, "init", "-q", "--bare")

proc refs(bare: string): seq[string] =
  ## The refs a bare repo holds, e.g. `refs/heads/main`.
  gitOk(bare, "for-each-ref", "--format=%(refname)").splitLines.filterIt(it.len > 0).sorted

proc newRepo(): string =
  ## A friend's copy: branch `main` with a save point, plus a branch and a tag
  ## that are not the friend's saves.
  result = createTempDir("para_backup_", "")
  discard gitOk(result, "init", "-q")
  discard gitOk(result, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(result, "config", "user.name", "Scratch")
  discard gitOk(result, "config", "user.email", "scratch@example.com")
  discard gitOk(result, "config", "commit.gpgsign", "false")
  result.put("games/pong/pong.nim", "echo 1\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "start")
  discard gitOk(result, "tag", "save-pong-1")
  discard gitOk(result, "tag", "v1.0")
  discard gitOk(result, "branch", "scratch-work")

proc fakeGh(dir, answer: string): string =
  ## A `gh` that prints `answer` for any `repo view` ("fail" exits 1).
  result = dir / "gh"
  writeFile(result, "#!/bin/sh\nif [ \"" & answer & "\" = fail ]; then echo \"not logged in\" >&2; exit 1; fi\necho " & answer & "\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

const
  noGh = "/nonexistent/para-test-gh"
  fakeUrl = "https://github.com/alice/pong-backup"

suite "addresses: the same repository, however it is spelled":
  test "normUrl folds scheme, login, scp style, case, .git and slashes":
    let want = "github.com/pdepaula/parastudio"
    for u in ["https://github.com/PDepaula/parastudio", "https://github.com/PDepaula/parastudio.git",
              "git@github.com:PDepaula/parastudio.git", "ssh://git@github.com/PDepaula/parastudio/",
              "https://user:tok@github.com/PDepaula/parastudio", "HTTPS://GitHub.com/pdepaula/Parastudio.git"]:
      check normUrl(u) == want
    check normUrl("/tmp/a/b.git") == "/tmp/a/b"

  test "hasCredentials sees any login in an http(s) address, not ssh forms":
    check hasCredentials("https://alice:ghp_secret@github.com/alice/x")
    check hasCredentials("https://ghp_secret@github.com/alice/x")
    check hasCredentials("https://alice@github.com/alice/x")
    check hasCredentials("HTTP://alice:pw@github.com/alice/x")
    check not hasCredentials("https://github.com/alice/x")
    check not hasCredentials("https://github.com/alice/x@y")
    check not hasCredentials("git@github.com:alice/x.git")
    check not hasCredentials("ssh://git@github.com/alice/x.git")

  test "shown leaves the login out":
    check shown("https://alice:ghp_secret@github.com/alice/x") == "https://github.com/alice/x"
    check "secret" notin shown("https://alice:ghp_secret@github.com/alice/x")

  test "urlProblem: another remote's address, the Para Studio project, passwords, nothing":
    check urlProblem(@[fakeUrl], @["https://github.com/other/repo"]) == ""
    check urlProblem(@[fakeUrl], @[]) == ""
    check "same repository" in urlProblem(@["git@github.com:Alice/pong-backup.git"], @[fakeUrl])
    check "Para Studio project" in urlProblem(@["https://github.com/PDepaula/parastudio"], @[])
    check "Para Studio project" in urlProblem(@["git@github.com:pdepaula/parastudio.git"], @[])
    check urlProblem(@["https://github.com/alice/parastudio"], @[]) == "" # their own repo of that name
    check urlProblem(@["https://github.com/xpdepaula/parastudio"], @[]) == ""
    check "password" in urlProblem(@["https://alice:tok@github.com/alice/x"], @[])
    check "password" in urlProblem(@["https://ghp_tok@github.com/alice/x"], @[])
    check urlProblem(@["git@github.com:alice/x.git"], @[]) == ""
    check urlProblem(@["ssh://git@github.com/alice/x.git"], @[]) == ""
    check "no address" in urlProblem(@[], @[])
    # the push address counts too
    check "Para Studio project" in urlProblem(@[fakeUrl, "https://github.com/PDepaula/parastudio"], @[])

suite "para backup: with nothing to do":
  var root: string
  setup: root = newRepo()
  teardown: removeDir(root)

  test "--help, and flags that go nowhere alone":
    check runBackupWith(@["--help"], root).output.startsWith("para backup")
    check runBackupWith(@["--yes"], root).code == 2
    check runBackupWith(@["--is-private"], root).code == 2
    check runBackupWith(@["--bogus"], root).code == 2

  test "no backup remote: says so, with the steps, changes nothing":
    let r = runBackupWith(@[], root, noGh)
    check r.code == 0
    check "backup: not set up" in r.output
    check "git remote add backup" in r.output
    check "PRIVATE" in r.output
    check gitOk(root, "remote") == ""

  test "with gh installed the steps start from gh":
    let dir = createTempDir("para_backup_gh_", "")
    defer: removeDir(dir)
    let r = runBackupWith(@[], root, fakeGh(dir, "true"))
    check "gh repo create <a-name> --private --source . --remote backup" in r.output

  test "a push with no remote is refused and says how to set one up":
    let r = runBackupWith(@["--push", "--yes"], root, noGh)
    check r.code == 1
    check "no \"backup\" remote" in r.output
    check "Nothing was uploaded" in r.output

  test "status shows where it points, without the login":
    discard gitOk(root, "remote", "add", "backup", "ssh://alice@github.com/alice/pong-backup")
    let r = runBackupWith(@[], root, noGh)
    check r.code == 0
    check "github.com/alice/pong-backup" in r.output
    check "alice@" notin r.output
    check "branch: main" in r.output

suite "para backup --push: only to the friend's own private copy":
  var root, bare: string
  setup:
    root = newRepo()
    bare = newBare()
    discard gitOk(root, "remote", "add", "backup", bare)
  teardown:
    removeDir(root)
    removeDir(bare)

  test "without --yes it explains what goes where and uploads nothing":
    let r = runBackupWith(@["--push"], root, noGh)
    check r.code == 1
    check "Nothing was uploaded" in r.output
    check "--yes" in r.output
    check "main" in r.output
    check refs(bare).len == 0

  test "a local path or other host needs --is-private (gh cannot check it)":
    let r = runBackupWith(@["--push", "--yes"], root, noGh)
    check r.code == 1
    check "--is-private" in r.output
    check refs(bare).len == 0

  test "with --yes and --is-private: the branch and the save points go, nothing else":
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 0
    check "Backed up" in r.output
    check refs(bare) == @["refs/heads/main", "refs/tags/save-pong-1"]
    check gitOk(bare, "rev-parse", "main") == gitOk(root, "rev-parse", "main")

  test "a later backup sends only what is new, never rewriting the old":
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 0
    root.put("games/pong/pong.nim", "echo 2\n")
    discard gitOk(root, "commit", "-q", "-am", "more")
    discard gitOk(root, "tag", "save-pong-2")
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 0
    check refs(bare) == @["refs/heads/main", "refs/tags/save-pong-1", "refs/tags/save-pong-2"]

  test "an online copy that is ahead is never forced over":
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 0
    # the online copy gets a commit this copy lacks
    let other = createTempDir("para_backup_other_", "")
    defer: removeDir(other)
    discard gitOk(other, "clone", "-q", "-b", "main", bare, "w")
    discard gitOk(other / "w", "config", "user.name", "O")
    discard gitOk(other / "w", "config", "user.email", "o@example.com")
    other.put("w/x.txt", "x\n")
    discard gitOk(other / "w", "add", ".")
    discard gitOk(other / "w", "commit", "-q", "-m", "elsewhere")
    discard gitOk(other / "w", "push", "-q", "origin", "main")
    let theirs = gitOk(bare, "rev-parse", "main")
    root.put("games/pong/pong.nim", "echo 2\n")
    discard gitOk(root, "commit", "-q", "-am", "more")
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check "the upload failed" in r.output
    check "never force" in r.output
    check gitOk(bare, "rev-parse", "main") == theirs

  test "a detached HEAD is refused":
    discard gitOk(root, "checkout", "-q", "--detach")
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check "detached" in r.output
    check refs(bare).len == 0

suite "para backup --push: gh decides when it can":
  var root, bare, ghDir: string
  setup:
    root = newRepo()
    bare = newBare()
    ghDir = createTempDir("para_backup_gh_", "")
    # a github.com address for gh to be asked about, pushed to the local bare repo
    discard gitOk(root, "remote", "add", "backup", fakeUrl)
    discard gitOk(root, "config", "url." & bare & ".pushInsteadOf", fakeUrl)
  teardown:
    removeDir(root)
    removeDir(bare)
    removeDir(ghDir)

  test "gh says private: it goes, no --is-private needed":
    let r = runBackupWith(@["--push", "--yes"], root, fakeGh(ghDir, "true"))
    check r.code == 0
    check refs(bare) == @["refs/heads/main", "refs/tags/save-pong-1"]

  test "gh says public: refused even with --is-private":
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, fakeGh(ghDir, "false"))
    check r.code == 1
    check "PUBLIC" in r.output
    check refs(bare).len == 0

  test "gh cannot say (not logged in): refused even with --is-private, login is the friend's":
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, fakeGh(ghDir, "fail"))
    check r.code == 1
    check "gh auth login" in r.output
    check refs(bare).len == 0

  test "no gh at all: the friend's word (--is-private) is needed":
    check runBackupWith(@["--push", "--yes"], root, noGh).code == 1
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 0

suite "para backup --push: never origin, never the Para Studio project":
  var root, bare, origin: string
  setup:
    root = newRepo()
    bare = newBare()
    origin = newBare()
    discard gitOk(root, "remote", "add", "origin", origin)
  teardown:
    removeDir(root)
    removeDir(bare)
    removeDir(origin)

  test "a push only ever goes to backup: origin stays empty":
    discard gitOk(root, "remote", "add", "backup", bare)
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 0
    check refs(origin).len == 0
    check refs(bare).len == 2

  test "backup pointing at origin is refused, in any spelling":
    discard gitOk(root, "remote", "add", "backup", origin & "/")
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check "same repository as another remote" in r.output
    check refs(origin).len == 0

  test "backup pointing at any other remote is refused":
    discard gitOk(root, "remote", "add", "friend", bare)
    discard gitOk(root, "remote", "add", "backup", bare)
    check runBackupWith(@["--push", "--yes", "--is-private"], root, noGh).code == 1
    check refs(bare).len == 0

  test "a push address that differs from the fetch address counts (pushurl to origin)":
    discard gitOk(root, "remote", "add", "backup", bare)
    discard gitOk(root, "remote", "set-url", "--push", "backup", origin)
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check refs(origin).len == 0
    check runBackupWith(@[], root, noGh).code == 1 # status says there is a problem too

  test "the Para Studio project itself is refused, even with no origin":
    discard gitOk(root, "remote", "remove", "origin")
    discard gitOk(root, "remote", "add", "backup", "git@github.com:PDepaula/parastudio.git")
    let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check "Para Studio project" in r.output
    check "Nothing was uploaded" in r.output

  test "an http(s) address with a login in it is refused, and the secret is not printed":
    for url in ["https://alice:ghp_topsecret@github.com/alice/pong-backup",
                "https://ghp_topsecret@github.com/alice/pong-backup"]:
      discard runCaptured("git", @["remote", "remove", "backup"], root)
      discard gitOk(root, "remote", "add", "backup", url)
      let r = runBackupWith(@["--push", "--yes", "--is-private"], root, noGh)
      check r.code == 1
      check "login, password or token" in r.output
      check "topsecret" notin r.output
      let s = runBackupWith(@[], root, noGh)
      check "topsecret" notin s.output
