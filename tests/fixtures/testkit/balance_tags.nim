# Fixture for tests/test_testkit.nim: one test of every kind. The test
# compiles and runs this file as a child with PARALOOP_BALANCE set and reads
# its output, so the skip is checked on the real unittest formatter. A body
# that runs prints a `RAN <name>` line, so "skipped" means the body never ran.

import std/unittest except test
import paraloop/testkit

suite "kinds":
  test "invariant":
    echo "RAN invariant"
  balanceTest "pin":
    echo "RAN pin"
  playtestRule "rule":
    echo "RAN rule"
  mixedTest "mixed":
    echo "RAN mixed invariant half"
    balance:
      echo "RAN mixed pin half"
