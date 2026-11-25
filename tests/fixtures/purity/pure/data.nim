## Content rows, including a table of procs a `then` calls (`stepCost[kind](n)`).
import std/[strutils, tables]
import paraloop/toml

const startingHp* = 10

let
  stepCost*: array[2, proc (n: int): int {.noSideEffect, nimcall.}] = [
    proc (n: int): int = n,
    proc (n: int): int = n * 2]
