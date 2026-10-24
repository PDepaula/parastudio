# Fixture for tests/test_testkit.nim: one file of the test group group.nim. Its first
# test is a `mixedTest`, so that tag is the one that has to name this file.

import std/unittest except test
import paraloop/testkit

suite "grouped c":
  mixedTest "c mixed":
    echo "RAN c mixed"
  test "c second":
    echo "RAN c second"
