# Positive control for tests/test_render2d.nim: a manifest that matches its
# enum exactly should compile clean.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
size 10 10
a 0 0 4 4
b 5 5 4 4
""", staticRead("image10x10.png"))
