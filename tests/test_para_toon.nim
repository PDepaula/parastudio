# Tests for `para`'s TOON table writer (tools/para/art/toon.nim): a cell that
# would break the row's shape -- the delimiter, a quote, a colon, a newline,
# edge whitespace -- is quoted, and plain cells stay bare.

import std/[unittest, json]
import tools/para/art/toon

suite "toonTable cell quoting":
  test "plain cells stay bare":
    check toonTable("t", ["a", "b"], @[@["hello", "12"]]) == "t[1]{a,b}:\n  hello,12\n"

  test "a comma, colon, quote, newline or edge space is quoted, so each row keeps its column count":
    let msg = "type mismatch: got <int, float>"
    let row = toonTable("errors", ["at", "msg"], @[@["src/x.nim:3", msg]])
    check row == "errors[1]{at,msg}:\n  \"src/x.nim:3\",\"type mismatch: got <int, float>\"\n"
    check toonCell("say \"hi\"") == "\"say \\\"hi\\\"\""
    check parseJson(toonCell("two\nlines")).getStr == "two\nlines"
    check toonCell(" padded") == "\" padded\""
    check toonCell("") == "\"\""
