# tests/test_render2d.nim expects this to fail `nim check`: the manifest
# names "c", which is not a value of `Sprite`.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
size 10 10
a 0 0 4 4
b 5 5 4 4
c 0 5 4 4
""", staticRead("image10x10.png"))
