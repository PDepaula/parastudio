# paraloop/dev is meant to be used only behind `-d:dev` (see its module doc);
# this project-scoped config (loaded only for tests/test_dev.nim's own build,
# on top of tests/config.nims and the root config.nims) is what turns it on
# for this file's compile, the same way a game opts in.
switch("define", "dev")
