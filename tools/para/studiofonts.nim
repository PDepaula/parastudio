# The Studio Desk fonts, inside the page that uses them: Nunito for text and Fredoka for headings,
# Latin only (SIL OFL 1.1; studio/fonts/ holds the licences). The Studio page (studioapi.nim) and
# every visual board (boardcmd.nim) put the same @font-face lines in, so neither loads anything from
# anywhere else.

import std/[base64, os]

template fontFace(family: string, weight: int, file: static string): string =
  ## One @font-face whose font is inside the page.
  "@font-face { font-family: \"" & family & "\"; font-weight: " & $weight &
    "; font-style: normal; font-display: swap; src: url(\"data:font/woff2;base64," &
    encode(staticRead("studio" / "fonts" / file)) & "\") format(\"woff2\"); }\n"

const
  ## About 65 KB of fonts, 87 KB once inlined.
  fontFaces* = fontFace("Nunito", 400, "nunito-latin-400-normal.woff2") &
    fontFace("Nunito", 700, "nunito-latin-700-normal.woff2") &
    fontFace("Nunito", 800, "nunito-latin-800-normal.woff2") &
    fontFace("Fredoka", 600, "fredoka-latin-600-normal.woff2")
