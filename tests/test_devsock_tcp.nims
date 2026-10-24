# This project-scoped config (loaded only for tests/test_devsock_tcp.nim's own
# build, on top of tests/config.nims and the root config.nims) selects the
# loopback TCP route for `paraloop/devsock`, the same way test_dev.nims turns
# on `dev` for tests/test_dev.nim.
switch("define", "devTcp")
