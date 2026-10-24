# Issue #41: keeps `para_art_fix`'s Python outline classification in sync
# with `tools/para/art/lint.nim::analyzeAsset`'s own boundary/interior/luma
# rule by running both against the exact same PNG fixtures and the same
# recorded expectation - tests/fixtures/art/outline/cases.json - instead of
# trusting a hand-copied reimplementation on the Python side.
# tools/art/tests/test_outline.py is this file's Python counterpart; the
# fixtures themselves are the shapes tests/test_art_lint.nim's own "outline
# and palette rules" suite already exercises (block5/solidCell/diamond), so
# this isn't new logic, just the same cases run through a real file so a
# second language can load the identical bytes.

import unittest
import std/[json, os]
import stb_image/read as stbi
import tools/para/art/[lint, profile]

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art" / "outline"

type Case = object
  file: string
  cellW, cellH: int
  outlineOffenders: int

proc loadCases(): seq[Case] =
  let j = parseFile(fixturesDir / "cases.json")
  for node in j:
    result.add Case(
      file: node["file"].getStr,
      cellW: node["cell_w"].getInt,
      cellH: node["cell_h"].getInt,
      outlineOffenders: node["outline_offenders"].getInt)

suite "para_art_fix outline classification stays in sync with lint.nim (issue #41)":
  test "every shared fixture's outlineOffenders matches the recorded expectation":
    for c in loadCases():
      checkpoint c.file
      var w, h, channels: int
      let pixels = stbi.load(fixturesDir / c.file, w, h, channels, stbi.RGBA)
      check (w, h) == (c.cellW, c.cellH)
      let r = analyzeAsset(pixels, w, h, c.cellW, c.cellH, builtinHiBit, "bottom")
      check r.cellsMeasured
      check r.outlineOffenders == c.outlineOffenders
