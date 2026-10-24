# tests/test_render2d.nim expects this to fail `nim check`: enum value `B`
# has no line in the manifest.
import paraloop/render2d

type Sprite = enum
  A, B

const atlas = parseAtlas(Sprite, """
size 10 10
a 0 0 4 4
""", staticRead("image10x10.png"))
