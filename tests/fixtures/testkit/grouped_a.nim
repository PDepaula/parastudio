# Fixture for tests/test_testkit.nim: one file of the test group group.nim. Its first
# test is a `playtestRule`, so that tag is the one that has to name this file.

import std/unittest except test
import paraloop/testkit

suite "grouped a":
  playtestRule "a rule":
    echo "RAN a rule"
  test "a second":
    echo "RAN a second"
