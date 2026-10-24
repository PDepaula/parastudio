# Roadmap

A list of directions, not commitments. Order does not mean priority, and
anything here can change or be dropped.

## Limited 3D support

Status: exploratory.

Voxel blocks or low-poly shapes, flat colours only. First slice:

- a fixed tilted camera, no free look
- no texturing
- everything else stays 2D

A spike of one to two days comes first: a small `cube3d` example with
pass/fail checks, including the web build and a run on an integrated-GPU
laptop. Two gates decide whether it goes further:

- the web build must work
- weak machines must run it acceptably

Prior art: the paranim example
[`voxel_explorer`](https://github.com/paranim/paranim_examples/tree/master/voxel_explorer)
(by Zach Oakes, public domain) renders a Minecraft-style terrain with Sean
Barrett's `stb_voxel_render.h`. It compiles against the versions this repo
pins, but it cannot be the base. Its shaders read face data through an OpenGL
texture buffer, and WebGL2 has no texture buffers. The example's own history
says its web build fails at link time for that reason. Reusing the header
would mean rewriting that data path and maintaining a fork.

## Documentation website

Status: planned.

A site in the Studio's look, built from the files in `docs/`.

## Windows and Mac verification

Status: planned.

The owner or a friend runs the Windows and Mac launchers on real machines.
Today they are only exercised with stand-ins, Wine or hosted runners.

## Studio sessions list

Status: not started.

Past conversations in the Studio sidebar. It needs the chat store to keep
more than one conversation per game and producer.
