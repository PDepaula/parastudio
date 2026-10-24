# The whole of test_para_studio_play on the loopback TCP route of the dev control channel (the
# Windows one: `tmp/dev.sock` is a file holding a port number), run here on any OS:
# test_para_studio_play_tcp.nims defines `devTcp` for this build, the same way test_devsock_tcp
# does for test_devsock. So the studio's ping and screenshot request, and the fake game's listener,
# take the code path a Windows friend's game window uses.

include test_para_studio_play
