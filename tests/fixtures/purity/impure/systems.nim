import pararules
import std/monotimes                     # BAD 2: the clock
when defined(dev): import std/os          # BAD 3: one line, behind a when
elif defined(web): import std/times       # BAD 4: one line, behind an elif
else: import std/rdstdin                  # BAD 5: one line, behind an else
import                                    # BAD 6: `import` alone, the modules on the lines below
  std/strutils,
  std/oids
from std/parseopt import                  # BAD 9: the names on the line below
  initOptParser

proc stamp*(): string =
  ## A game proc a then calls (rules.nim's loader): its effects are refused here.
  echo "stamping"                         # BAD 14: output
  read_file("save.txt")                   # BAD 15: a file, spelled the other way Nim allows
