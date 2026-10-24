# The one registry of games linked into `para` itself: `sim` and `shot` run these in
# process. Every other game reaches them through its own driver program
# (driverexec.nim), so adding a linked game is one driver module and one line here.

import std/options
import gamedriver
import hellodriver

proc linkedSim*(name: string): Option[SimDriver] =
  case name
  of "hello": some(helloSimDriver())
  else: none(SimDriver)

proc linkedShot*(name: string): Option[ShotDriver] =
  case name
  of "hello": some(helloShotDriver())
  else: none(ShotDriver)
