# Fixture for tests/test_testkit.nim: a test group, four test files as one program
# (the shape of a game's tests/pin_tests.nim). group.nims builds it with
# `-d:paraloopTestGroup`, which is what makes each file's first tag name the file.

{.warning[UnusedImport]: off.}

import paraloop/testkit
import grouped_a
import grouped_b
import grouped_c
import grouped_d

echo finishedPrefix, "tests/fixtures/testkit/group.nim"
