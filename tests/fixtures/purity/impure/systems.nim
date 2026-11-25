import pararules
import std/monotimes                     # BAD 2: the clock
when defined(dev): import std/os          # BAD 3: one line, behind a when
