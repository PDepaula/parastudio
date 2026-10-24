## `tune`: a line of music as tones. A small text score (a subset of the note
## syntax of Alda and MML) turned into `seq[Tone]`, so a melody drops into a
## `Recipe` row beside hand-written tones. Pure Nim over `paraloop/audio`: no
## device, and it runs at compile time, so a `const` row can be written with it.
##
##   c d e f g a b   a note; `+` sharp, `-` flat after the letter (`f+`, `b-`)
##   r               a rest
##   c8  r4          a length: 4 = quarter note, 8 = eighth; it sticks until changed
##   o5  >  <        set the octave; one up; one down (o4 holds middle C)
##   c/e/g           a chord: notes joined by `/` start together
##   spaces and `|`  ignored, so a bar line can group the beats
##
## Worked example, a rising level-up arpeggio:
##
##   const levelUp = Recipe(name: "level_up", tones: tune("o5 c16 e g >c", Square))
##
## At the default 120 quarter notes a minute a whole note lasts 2000 ms, so
## `c16` is 125 ms and the four tones (MIDI 72, 76, 79, 84) start at 0, 125,
## 250 and 375 ms. A bad character raises `ValueError` naming its position
## (counted from 0). It is a deliberately small notation: no voices, repeats,
## variables or instruments.

import std/parseutils
import paraloop/audio

const semitone = [9, 11, 0, 2, 4, 5, 7] ## a b c d e f g, above the octave's C

func fail(text: string, at: int, what: string) {.noreturn.} =
  raise newException(ValueError, "tune: " & what & " at " & $at & " in \"" & text & "\"")

func tune*(text: string, wave = Triangle, tempo = 120, gain = 0.4): seq[Tone] =
  ## The tones `text` plays at `tempo` quarter notes per minute, in `wave`.
  if tempo < 1: raise newException(ValueError, "tune: tempo " & $tempo & " is below 1")
  var
    i = 0
    octave = 4
    length = 4 ## 4 = a quarter note
    atMs = 0 ## where the next note or chord starts
    chordMs = 0 ## how far the chord being read moves `atMs`
  let wholeMs = 4 * 60000 div tempo
  while i < text.len:
    let at = i
    let ch = text[i]
    inc i
    case ch
    of 'o':
      let n = parseInt(text, octave, i)
      if n == 0: fail(text, at, "'o' needs an octave number")
      i += n
    of '>': inc octave
    of '<': dec octave
    of 'a' .. 'g', 'r':
      var note = float(12 * (octave + 1))
      if ch != 'r': note += float(semitone[ord(ch) - ord('a')])
      while i < text.len and text[i] in {'+', '-'}:
        note += (if text[i] == '+': 1.0 else: -1.0)
        inc i
      i += parseInt(text, length, i)
      if length < 1: fail(text, at, "a length below 1")
      let ms = wholeMs div length
      if ch != 'r': result.add tone(wave, atMs, ms, note, gain = gain)
      chordMs = max(chordMs, ms)
      if i < text.len and text[i] == '/': inc i # the next note joins this chord
      else:
        atMs += chordMs
        chordMs = 0
    of ' ', '\t', '\n', '\r', '|': discard
    else: fail(text, at, "unexpected '" & ch & "'")
