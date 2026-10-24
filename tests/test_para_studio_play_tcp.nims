# This project-scoped config (loaded only for tests/test_para_studio_play_tcp.nim's own build, on
# top of tests/config.nims and the root config.nims) selects the loopback TCP route for
# `paraloop/devsock`, the same way test_devsock_tcp.nims does.
switch("define", "devTcp")
