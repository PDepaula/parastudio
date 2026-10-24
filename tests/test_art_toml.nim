import unittest
import std/tables
import paraloop/toml

suite "toml: the minimal style.toml/sidecar/tuning.toml subset":
  test "flat key = value pairs, quoted and bare":
    let doc = parseToml("""
      # a comment
      name = "hibit"
      max_colors = 48
      outline_required = true
    """)
    check doc.top.getStr("name") == "hibit"
    check doc.top.getInt("max_colors", 0) == 48
    check doc.top.getBool("outline_required", false) == true

  test "an inline # comment is not part of the value, but a # inside quotes is":
    let doc = parseToml("""
      pivot = "bottom" # feet on the baseline
      max_colors = 24   # hi-bit budget
      reason = "see issue #12" # why
      [[waiver]] # the ghost
      rule = "alpha"
    """)
    check doc.top.getStr("pivot") == "bottom"
    check doc.top.getInt("max_colors", 0) == 24
    check doc.top.getStr("reason") == "see issue #12"
    check doc.arrays["waiver"][0].getStr("rule") == "alpha"

  test "a value that isn't the expected type names its key":
    let doc = parseToml("cell_w = 64px\noutline_required = maybe\n")
    expect(ValueError):
      discard doc.top.getInt("cell_w", 0)
    expect(ValueError):
      discard doc.top.getBool("outline_required", false)
    try:
      discard doc.top.getInt("cell_w", 0)
    except ValueError as e:
      check e.msg == "cell_w: expected an integer, got 64px"

  test "[[array]] of tables collects one entry per header":
    let doc = parseToml("""
      cell_w = 64

      [[waiver]]
      rule = "alpha"
      reason = "translucent by design"

      [[waiver]]
      rule = "colors"
      reason = "placeholder art"
    """)
    check doc.top.getInt("cell_w", 0) == 64
    check doc.arrays["waiver"].len == 2
    check doc.arrays["waiver"][0].getStr("rule") == "alpha"
    check doc.arrays["waiver"][1].getStr("reason") == "placeholder art"

  test "missing keys fall back to the given default":
    let doc = parseToml("present = \"yes\"")
    check doc.top.getStr("absent", "fallback") == "fallback"
    check doc.top.getInt("absent", 7) == 7

  test "getFloat reads a decimal, an integer and the default, and names a bad key":
    let doc = parseToml("scale = 1.5\nwhole = 3\nbad = fast\n")
    check doc.top.getFloat("scale", 0.0) == 1.5
    check doc.top.getFloat("whole", 0.0) == 3.0
    check doc.top.getFloat("absent", 0.25) == 0.25
    try:
      discard doc.top.getFloat("bad", 0.0)
      check false
    except ValueError as e:
      check e.msg == "bad: expected a number, got fast"

  test "the compile-time VM can parse an embedded file (a game's tuning.toml is read in a const)":
    const doc = parseToml("a = 4\nb = 2.5\n")
    check doc.top.getInt("a", 0) == 4
    check doc.top.getFloat("b", 0.0) == 2.5
