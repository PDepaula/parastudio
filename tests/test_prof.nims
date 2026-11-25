# paraloop/prof records only in a `-d:prof` build (see its module doc); this
# project-scoped config (loaded only for tests/test_prof.nim's own build, on
# top of tests/config.nims and the root config.nims) turns the seams on for
# this file's compile, the same way a measuring build does.
switch("define", "prof")
