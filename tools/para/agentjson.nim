# Reading an agent's JSON without ever raising: every adapter parses lines it does not control, so
# a missing key or a value of the wrong type gives nil, "", -1 or false instead of an exception.

import std/json

proc at*(n: JsonNode, key: string): JsonNode =
  if n != nil and n.kind == JObject and n.hasKey(key): n[key] else: nil

proc at*(n: JsonNode, keys: varargs[string]): JsonNode =
  result = n
  for k in keys: result = result.at(k)

proc str*(n: JsonNode, keys: varargs[string]): string =
  let v = n.at(keys)
  if v != nil and v.kind == JString: v.getStr else: ""

proc num*(n: JsonNode, keys: openArray[string]): int =
  let v = n.at(keys)
  if v != nil and v.kind == JInt: v.getInt else: -1

proc flag*(n: JsonNode, keys: varargs[string]): bool =
  let v = n.at(keys)
  v != nil and v.kind == JBool and v.getBool
