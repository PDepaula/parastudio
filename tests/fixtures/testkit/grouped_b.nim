# Fixture for tests/test_testkit.nim: one file of the test group group.nim. Its first
# test is a `balanceTest`, so that tag is the one that has to name this file.

import std/unittest except test
import paraloop/testkit

suite "grouped b":
  balanceTest "b pin":
    echo "RAN b pin"
  test "b second":
    echo "RAN b second"
