# Platforms

What a first playable needs on macOS and Windows, measured on GitHub-hosted
runners (`macos-latest` = macOS 26 arm64, `windows-latest` = Windows Server,
x64) by `.github/workflows/platform-check.yml` on 2026-10-18/19. Linux is what
CI uses everywhere else; its path (about 33 s from a clone to a built, tested
new game) is the baseline.

**Status: the hosted jobs are paused until 2026-11-01** (GitHub-hosted runner
minutes are used up for the month), so for now the project owner's own try of
[windows-first-game.md](windows-first-game.md) on a Windows VM is the check.
What the last hosted Windows runs that executed showed: new game, build,
`test --filter games/mygame/`, the `nim c -d:dev` compile and the `test_dev`
tests (including the devsock tests) passed. In that run `test_para_dev_cli`
aborted in its "no display" screenshot test (GLFW assertion, no OpenGL on the
runner); that test was then changed to run only on Linux, and that fix and
everything after it has **not** been re-run on Windows. Opening a window was
never checked and needs real hardware. The "set up to run" wording below
describes what the workflow does when it is switched back on.

**Double-click launcher on Windows:** `Paraloop-Studio.bat` ([windows.md](windows.md)) is not
covered by the table below; the `windows-launcher` job in the same workflow dry-runs it (by hand
only, and not run yet), and nobody has run it on a real Windows PC.

**Trying it on a real Windows PC or VM?** Follow
[windows-first-game.md](windows-first-game.md): the installs, the exact
commands and what to report back. A VM may give only software OpenGL, in which
case the window will not open.

The path checked, from a fresh clone:

```
nimble install -d -y && nimble setup
nim c --hints:off --outdir:tmp tools/para/para.nim
tmp/para new mygame
tmp/para build --game mygame
tmp/para test --filter games/mygame/
tmp/para shot --game hello --at title        # opens a hidden GL window
```

On Windows the check is also set up to run the dev tool (the control channel `para live`
talks to), headless: `para test --filter test_dev`, `--filter test_para_dev_cli`
(a listener and `para live` in one process, no window), a smoke run of the bare `para` view (it starts with no game
listening, so it does not test the live ping), a smoke run of `para studio --no-open` (`.github/scripts/studio-smoke.sh`: the page loads, the state call answers, a call without the key gets 403, and, when `claude` is not installed, one chat message ends with the plain "not installed" answer; then it presses Play, which builds the game and tries its window and must end in a plain sentence, here most likely about missing graphics, or with a screenshot if a window does open), and a compile of the new game with `nim c -d:dev games/mygame/mygame.nim`, the
command that opens the window minus `-r`. **Opening a window is not checked as a
pass:** a hosted runner has no GPU, so that step is a recorded fact, and
whether a window opens needs real hardware.

## Result

| | macOS (arm64) | Windows (x64) |
|---|---|---|
| Nim + nimble | works after installing Nim | works after installing Nim |
| `nimble install -d -y`, `nimble setup` | works | works |
| build `para` | works | was **broken**: `src/paraloop/dev.nim(325): undeclared routine 'bindUnix'`; fixed (see below) |
| `para new` + `build` + `test --filter` | works | works (run 3 with a stopgap shim; the test step also needed a `paraloop.nimble` path fix, since landed) |
| dev tool (`paraloop/dev` channel, `para live`) | unix socket, tested on Linux CI | loopback TCP, tested on Linux CI by `tests/test_devsock_tcp.nim` (`-d:devTcp`); the same tests passed on the last hosted Windows runs that executed (`test_dev`), but that check is now paused and the later commits were not re-run there |
| a window opens | **not on a hosted runner** (no GPU) | **not on a hosted runner** (no GPU) |

## Prerequisites per OS

| Needed | macOS | Windows |
|---|---|---|
| git | preinstalled (2.56) | preinstalled (Git for Windows 2.56, includes bash) |
| C compiler | preinstalled Apple clang 21 (`cc`, `gcc` and `clang` are all clang; Xcode Command Line Tools on a friend's Mac) | preinstalled MinGW-w64 gcc 15.2 (also clang 20) |
| Nim 2.2.10 + nimble | **not preinstalled.** `jiro4989/setup-nim-action@v2` builds Nim from source on arm64 (`koch boot`): 134-169 s. A friend's `choosenim`/`brew` install differs | **not preinstalled.** The action unpacks the official zip: 8-16 s, no compiler needed |
| window/GL libraries | none to install (Cocoa and OpenGL ship with the OS; the GLFW sources come with the `nimgl` package) | none to install (the `nimgl` package bundles GLFW; the GL driver comes with the GPU driver) |
| anything else | nothing | nothing |

`nimble install -d -y` fetches the other seven dependencies from git and, as on
Linux, needs only git and network access. No Xcode, Homebrew, MSYS2, Visual
Studio or Python was needed for this path.

## Step times (wall seconds, one hosted run each, no cache)

Measured before the dev-channel fix: the Windows column is run 3 with the
stopgap shim (without it `build para` failed after 3 s). The dev-tool steps
added since have no timings here; the hosted jobs are paused until 2026-11-01.

| Step | macOS | Windows |
|---|---:|---:|
| install Nim and nimble (setup action) | 134 to 169 (runs 1-3: 137, 169, 134) | 8 to 16 |
| `nimble install -d -y` | 18 to 19 | 27 to 35 |
| `nimble setup` | 0 to 1 | 0 to 1 |
| `nim c ... tools/para/para.nim` | 14 to 16 | 61 to 63 |
| `para new mygame` | 0 | 0 |
| `para build --game mygame` | 4 to 6 | 19 to 20 |
| `para test --filter test_mygame` (now `games/mygame/`, same file) | 5 to 6 (5 tests pass) | 20 (passes) |
| whole job | 185 s | 186 s |

## Windows: what broke and the fix

1. **`para` did not compile.** `std/net`'s `bindUnix`/`connectUnix` exist only
   on POSIX; `src/paraloop/dev.nim` (the `-d:dev` control channel), `tools/para/devclient.nim`
   (`para live`) and `tools/para/homecmd.nim` (the bare view's live ping) use
   them. Run 3 got through with a shim that raised on Windows (the channel simply
   off). Now `src/paraloop/devsock.nim` gives the channel a real Windows path: a
   loopback TCP listener (127.0.0.1, an OS-picked port) with the port written to
   the usual channel path (`tmp/dev.sock`), which `para live`, the bare view and
   the stale-file cleanup keep using unchanged. It was chosen over Windows 10+'s
   `AF_UNIX` because that would need raw `sockaddr_un` calls and an untested
   `accept` and file-info path on a socket reparse point, while TCP uses only
   calls every platform already runs and can be tested on Linux (`-d:devTcp`).
   The cost: any local process can connect to a loopback port, which is fine for
   a `-d:dev` tool and nothing else. POSIX is unchanged.
2. **`para test --filter` failed with "test plan entry not run".** The test
   task compared a plan entry written with `/` against a path joined with `\`.
   Fixed in `paraloop.nimble` in this PR (the plan entry is compared with the
   separator normalised).

## Windows and macOS: no window on a hosted runner

`para shot` (a hidden GL 3.3 core window, the same call a game's window makes)
aborts on both. GLFW's own error text, from `.github/scripts/glprobe.nim`, for
a hidden core window, a visible core window and a default-hint window:

- macOS: `NSGL: Failed to find a suitable pixel format` (session `Aqua`, so a
  window server exists, but the VM has no GPU)
- Windows: `WGL: The driver does not appear to support OpenGL` (no GPU driver)

So a hosted runner cannot say whether a friend's own Mac or PC opens a window;
that needs a person on real hardware. What *was* confirmed: the engine builds,
and `glfwInit` succeeds on both.

One real finding behind the abort: when `glfwCreateWindow` fails, `nimgl`'s
wrapper calls `glfwSetWindowIcon` on the nil window, which asserts
(`window != NULL`, `window.c:516`). `src/paraloop/app.nim`'s `createWindow` checks
for a nil window, but never gets the chance. A friend with no usable GL gets a
`SIGABRT` rather than the nil-window path. Passing `icon = false` to
`glfwCreateWindow` would reach it; not changed here.

## Re-running

The job is currently switched off (`if: false`, paused until 2026-11-01);
delete that line to re-enable it. The workflow runs only on `workflow_dispatch` (once it exists on the default
branch; its own `pull_request` trigger is paused; the other CI workflows run
automatically, see "Running the checks on demand" in [testing.md](testing.md)). It is
paid time on a private repo (macOS minutes cost 10x, Windows 2x), so it has no
schedule, no push trigger and no cache.
