# Fixture for tests/test_testkit.nim: one file of the test group group.nim. Its first
# test is a `test`, so that tag is the one that has to name this file.

import std/unittest except test
import paraloop/testkit

suite "grouped d":
  test "d invariant":
    echo "RAN d invariant"
  test "d second":
    echo "RAN d second"
