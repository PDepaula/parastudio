# tests/test_render2d.nim expects this to fail `nim check`: the manifest has no
# `size` line.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
a 0 0 4 4
b 5 5 4 4
""", staticRead("image10x10.png"))
