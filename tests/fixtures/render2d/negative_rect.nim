# tests/test_render2d.nim expects this to fail `nim check`: b's rect has a
# negative height.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
size 10 10
a 0 0 4 4
b 5 5 4 -4
""", staticRead("image10x10.png"))
