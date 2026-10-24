"""para_art_fix: the Python half of `para art fix` (asset pipeline report
§6.1, §8.2, §9 row A2). Nim (`tools/para/art/fix.nim`) resolves each asset's
parameters from its flags and the nearest art/style.toml (fix reads no
`<name>.art.toml` sidecar), then calls `uv run --locked --project tools/art
python -m para_art_fix` with a JSON request on stdin and reads a JSON result
from stdout - this package never reads style.toml itself.
"""
