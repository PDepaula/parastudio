# tests/test_render2d.nim expects this to fail `nim check`: the manifest says
# 12x10 but image10x10.png is 10x10.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
size 12 10
a 0 0 4 4
b 5 5 4 4
""", staticRead("image10x10.png"))
