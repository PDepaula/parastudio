# Opening the friend's default browser on a link, for `para studio` (the page) and `para board`
# (a visual board), without waiting for the browser.

import std/[os, osproc]
when defined(windows):
  import std/browsers

proc openInBrowser*(url: string): bool =
  ## Starts the default browser on `url` without waiting for it: ShellExecute on Windows, `open` on
  ## macOS, `xdg-open` elsewhere (in its own session, so Ctrl+C here does not close the browser).
  ## False when none could be started; the caller then just prints the link.
  when defined(windows):
    openDefaultBrowser(url)
    true
  else:
    var exe = if defined(macosx): "open" else: "xdg-open"
    var args = @[url]
    if not defined(macosx) and findExe("setsid").len > 0:
      args = @[exe, url]
      exe = "setsid"
    if findExe(exe).len == 0: return false
    try:
      let p = startProcess(exe, args = args, options = {poUsePath, poParentStreams})
      defer: p.close()
      # xdg-open can stay alive as the browser itself; only a quick failure counts
      for _ in 0 ..< 15:
        if not p.running: return p.peekExitCode == 0
        sleep(100)
      true
    except OSError:
      false
