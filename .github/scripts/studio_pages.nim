# Draws the studio's two interactive model pages into a folder, for CI to upload: the
# `eversince pic <model.em> <out.html> --html` page of tools/para/studiodesk.em (studio-model.html)
# and of tools/para/studio-plan.em (studio-plan.html). They are not committed: a small model change
# redraws most of the page, a diff nobody can review. The SVG pictures beside them in docs/ are
# committed and tests/test_para_studio_model.nim holds them to the model files.
#
# Run from the repository root (after `nimble setup`):
#   nim r --hints:off .github/scripts/studio_pages.nim tmp/studio-pages
# It goes through eversince's own command line code, so a page is byte for byte what
# `eversince pic ... --html` writes.

import std/os
import eversince/cli

let outDir = if paramCount() >= 1: paramStr(1) else: "tmp/studio-pages"
createDir(outDir)
var failed = false
for (model, page) in [("tools/para/studiodesk.em", "studio-model.html"),
                      ("tools/para/studio-plan.em", "studio-plan.html")]:
  var s: Sink
  let code = dispatch(@["pic", model, outDir / page, "--html"], s)
  stdout.write s.outp
  stderr.write s.errp
  if code != 0:
    stderr.writeLine "error: could not draw " & page & " from " & model & " (exit " & $code & ")"
    failed = true
quit(if failed: 1 else: 0)
