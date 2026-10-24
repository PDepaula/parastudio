# Tests for paraloop/baseline (S4): the measured-baseline file, its tolerance bands, the
# comparison a balance test makes and the design bounds that fence a rebase. Pure: no bot
# is played, nothing is read from disk but the file it writes under tmp/.

import std/[unittest, os, strutils]
import paraloop/baseline

const sample = """
# header
tolerance_pct = 10
tolerance_floor_ticks = 120
tolerance_floor_count = 1

pace.s8.lock1_ticks = 2000
pace.s8.end_ticks = 26000

mirror.s1.copy_offers = 21
"""

proc base(): Baseline = parseBaseline(sample)

proc filterKinds(drifts: seq[Drift]): seq[DriftKind] =
  for d in drifts: result.add d.kind

suite "baseline: the file":
  test "parses the tolerance and the metrics in file order":
    let b = base()
    check b.tol == Tolerance(pct: 10, floorTicks: 120, floorCount: 1)
    check b.metrics == @[("pace.s8.lock1_ticks", 2000), ("pace.s8.end_ticks", 26000),
                         ("mirror.s1.copy_offers", 21)]

  test "a file without a tolerance gets the default":
    check parseBaseline("a.s1.x = 3").tol == defaultTolerance

  test "a metric that is not an integer, or a negative tolerance, is a ValueError naming it":
    expect ValueError: discard parseBaseline("a.s1.x_ticks = fast")
    expect ValueError: discard parseBaseline("tolerance_pct = -1")
    try: discard parseBaseline("a.s1.x_ticks = fast")
    except ValueError: check getCurrentExceptionMsg().contains("a.s1.x_ticks")

  test "render then parse is the identity, with a blank line between probes":
    let text = renderBaseline("two lines\nof header", defaultTolerance, base().metrics)
    check text.startsWith("# two lines\n# of header\n\ntolerance_pct = 10\n")
    check "\n\nmirror.s1.copy_offers = 21\n" in text
    let again = parseBaseline(text)
    check again.metrics == base().metrics
    check again.tol == defaultTolerance
    check renderBaseline("two lines\nof header", again.tol, again.metrics) == text

  test "loadBaseline reads a file from disk":
    let dir = currentSourcePath().parentDir.parentDir / "tmp" / "test-baseline"
    createDir(dir)
    writeFile(dir / "b.toml", sample)
    check loadBaseline(dir / "b.toml").metrics.len == 3

suite "baseline: tolerance bands":
  test "the band is a percent of the baseline, rounded up":
    let tol = Tolerance(pct: 10, floorTicks: 5, floorCount: 1)
    check tol.bandFor("a.s1.x_ticks", 2000) == 200
    check tol.bandFor("a.s1.x_ticks", 2001) == 201
    check tol.bandFor("a.s1.x_ticks", -2000) == 200

  test "a tick metric never gets less than the tick floor, a count never less than the count floor":
    check defaultTolerance.bandFor("a.s1.x_ticks", 100) == 120
    check defaultTolerance.bandFor("a.s1.copies", 5) == 1
    check defaultTolerance.bandFor("a.s1.copies", 0) == 1

suite "baseline: comparing a measurement":
  test "same, within the band, out of it, new and gone":
    let measured = @[("pace.s8.lock1_ticks", 2000), # same
                     ("pace.s8.end_ticks", 28000),  # +2000, band 2600: within
                     ("mirror.s1.copy_offers", 30), # +9, band 3: out
                     ("hub.s1.bought_ticks", 99)]   # no baseline entry
    let drifts = base().compare(measured)
    check drifts.len == 4
    check drifts[0].kind == dkSame
    check drifts[1].kind == dkWithin and drifts[1].band == 2600
    check drifts[2].kind == dkOut and drifts[2].baseline == 21 and drifts[2].measured == 30
    check drifts[3].kind == dkNew
    check base().compare(measured[0 .. 1]).filterKinds == @[dkSame, dkWithin, dkGone]

  test "only the baseline entries in scope can go missing":
    let measured = @[("pace.s8.lock1_ticks", 2000)]
    check base().compare(measured, @["pace.s8."]).filterKinds == @[dkSame, dkGone]
    check base().compare(measured, @["mirror."]).filterKinds == @[dkSame, dkGone]
    check base().compare(measured, @["pace.s8.lock1"]).filterKinds == @[dkSame]

  test "drifted keeps only what a check fails on":
    let drifts = base().compare(@[("pace.s8.lock1_ticks", 2000), ("pace.s8.end_ticks", 28000),
                                   ("mirror.s1.copy_offers", 30)], @["pace.s8."])
    check drifts.drifted.len == 1
    check drifts.drifted[0].key == "mirror.s1.copy_offers"

  test "deltaText shows the move and its percent; a one-sided metric shows a dash":
    check Drift(key: "a.s1.x", kind: dkOut, baseline: 200, measured: 230).deltaText == "+30 (+15.0%)"
    check Drift(key: "a.s1.x", kind: dkOut, baseline: 200, measured: 150).deltaText == "-50 (-25.0%)"
    check Drift(key: "a.s1.x", kind: dkNew, measured: 3).deltaText == "-"

  test "describe names the key, both numbers and the band":
    let line = Drift(key: "mirror.s1.copy_offers", kind: dkOut, baseline: 21, measured: 30,
                     band: 3).describe(defaultTolerance)
    check line.contains("mirror.s1.copy_offers")
    check line.contains("baseline 21") and line.contains("measured 30") and line.contains("+-3")

suite "baseline: design bounds":
  let bounds = @[Bound(pattern: "still.*.end_ticks", lo: 1, hi: 1800, why: "dies within 30 s"),
                 Bound(pattern: "pace.s8.end_ticks", lo: 18000, hi: 30000, why: "a run is 5 to 8 minutes")]

  test "a pattern's * matches exactly one part of the key":
    check "still.*.end_ticks".keyMatches("still.s3.end_ticks")
    check not "still.*.end_ticks".keyMatches("still.s3.lock1_ticks")
    check not "still.*.end_ticks".keyMatches("still.s3.x.end_ticks")
    check not "still.*".keyMatches("still.s3.end_ticks")

  test "violations lists a metric outside its bound with the reason, and nothing else":
    check bounds.violations(@[("still.s1.end_ticks", 995), ("pace.s8.end_ticks", 26000)]).len == 0
    let v = bounds.violations(@[("still.s1.end_ticks", 1801), ("other.s1.x", 99999)])
    check v.len == 1
    check v[0].contains("still.s1.end_ticks") and v[0].contains("1801") and v[0].contains("dies within 30 s")

  test "problems is a drifted metric, a missing one and a bound violation, in that order":
    let measured = @[("pace.s8.lock1_ticks", 2500), ("pace.s8.end_ticks", 30500)]
    let found = base().problems(bounds, measured, @["pace.s8."])
    check found.len == 3 # lock1 and end_ticks out of their bands, then end_ticks past its bound
    check found[0].contains("pace.s8.lock1_ticks")
    check found[1].contains("pace.s8.end_ticks") and found[1].contains("band")
    check found[2].contains("pace.s8.end_ticks") and found[2].contains("design bound")
    # a gone entry is reported too, when its key is in scope
    check base().problems(bounds, @[("pace.s8.lock1_ticks", 2000)], @["pace.s8."]).len == 1
    check base().problems(bounds, @[("pace.s8.lock1_ticks", 2100), ("pace.s8.end_ticks", 26000)],
                          @["pace.s8."]).len == 0

suite "baseline: merging a partial rebase":
  let old = @[("a.s1.x", 1), ("a.s2.x", 2), ("b.s1.x", 3)]

  test "no probes named: the fresh metrics replace everything":
    check merged(old, @[("c.s1.x", 9)], @[]) == @[("c.s1.x", 9)]

  test "a named probe is replaced in place, the others keep their place":
    check merged(old, @[("a.s1.x", 10), ("a.s2.x", 20)], @["a"]) ==
      @[("a.s1.x", 10), ("a.s2.x", 20), ("b.s1.x", 3)]

  test "a probe the old file lacks goes last":
    check merged(old, @[("c.s1.x", 9)], @["c"]) == old & @[("c.s1.x", 9)]

  test "a metric the fresh run no longer has leaves its probe":
    check merged(old, @[("a.s1.x", 10)], @["a"]) == @[("a.s1.x", 10), ("b.s1.x", 3)]
