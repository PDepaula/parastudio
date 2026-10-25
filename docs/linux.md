# Para Studio on Linux

Starting from nothing? The one-line installer ([Install with one line](install.md)) makes the
`parastudio` folder and runs this same launcher for you.

Run `./paraloop-studio.sh` from the `parastudio` folder. It takes the same steps, with the same
messages, as the Mac launcher ([mac.md](mac.md)); the C compiler is checked instead of Apple's
tools. If the C compiler or git is missing it shows the exact command for your package manager
(for example `sudo apt-get install build-essential`) and runs it only if you answer `y`; that
command asks for your password through `sudo`, and the package manager shows the size and asks
once more itself. Nim is offered the same way as on a Mac.

To type the steps yourself instead, see [Set up from a terminal](start.md). What was checked on
Linux, and how, is in [platforms.md](platforms.md).
