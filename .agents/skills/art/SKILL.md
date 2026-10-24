---
name: art
description: Art recipe the producer runs for a friend's game. Placeholder shapes by default; the friend may bring their own image generator. Covers one style sheet per asset class, sizes from the game's cell table, a credit ledger before any paid call, para art fix/lint, and a static review page for visual picks.
---

# Art

The producer runs this. Art is visible to the friend only as choices ("which look?"). Judge every asset at game size, never zoomed in.

## Default: placeholder shapes

Until the friend picks a generator, the game uses flat coloured shapes (the template's blue square is one). Placeholders are a finished answer for early tickets. Do not push art on a friend who is still deciding how the game plays. Offer real art once the first playable feels right.

## Generator: the friend's choice

- Ask once: "Do you have an image generator you like (a website, an app, your coding agent)? Or we stay with shapes for now." Record the answer in `CHOICES.md`.
- Name no generator as the answer. Do not claim that this host or any particular agent can make images; ask the friend, or test with one asset (below).
- Options to mention if they ask what is possible (each optional; shapes stay the default):
  - **Codex**, signed in on a paid plan (Plus, Pro, Business, Enterprise/Edu, or an API-key login; the Free plan is excluded). Ask in the session, for example "use $imagegen to make a top-down slime sprite on a transparent background". It uses the plan's usage limits and, past them, credits. Picture-making has been checked on a ChatGPT Plus plan. Not verified: the Go plan and Codex cloud tasks; do not promise those.
  - **Cursor** has a built-in image generator; it saves into the project's `assets/` folder by default.
  - **Claude Code** has no image generator. Bring your own (an image-generation MCP server, or a script with the friend's own API key), or keep the shapes.
- What Codex gives back is a PNG of about 1024 px, saved under `~/.codex/generated_images/`, with no control over size or seed, so the same prompt gives different art each time. It is not true pixel art. Ask Codex to copy the PNG you keep into `games/<game>/art/raw/`, then run the cleanup below (`para art fix` re-cells and palette-locks) before it goes in the game. Treat a kept image as a committed asset, never a step that is re-run.
- **Codex inside one conversation.** When the friend chose Codex and `codex` is installed and signed in on a paid plan, the art helper (never the builder) may run it from the same conversation, one picture per call: `codex exec --sandbox workspace-write 'use $imagegen to make <prompt>; copy the PNG you keep to games/<game>/art/raw/<name>.png'` (single quotes, so the shell leaves `$imagegen` alone). Write it in that one shape and chain nothing after it. The sandbox is `workspace-write` only, never `danger-full-access`, and no flag that loosens it. The friend approves each run when Claude Code asks. The ledger line comes first and the friend agrees to the count first. If Codex says it has no image tool (the Free plan) or prints a usage-limit or credit message, give the friend its words and stop: no retry, no second attempt in a loop, no other account.
- You prepare the prompts. The friend (or their chosen tool) produces the PNGs and drops them into `games/<game>/art/raw/`.
- Before a batch, do **one** test asset and show it at game size. The same prompt can look different in different tools; write the settings that worked into `STYLE.md`.

## Style sheet: one per asset class

`games/<game>/art/STYLE.md`, with one section per class: character, creature, item, effect, tile. Each section holds a style base (palette, outline, light direction, level of detail) written once.

- Build every prompt as: class style base + one line about the item. Never paste an item's words into a style base, and never mix two classes' bases (a style leaking into item prompts wastes paid generations).
- Keep a palette in the style sheet and reuse it.

## Sizes from the cell table

In `games/<game>/DESIGN.md`, keep an "Art cells" table: asset class, cell size in pixels (for example `player 32x48`), facings, frames. Decide a cell before generating anything.

- Generate at the cell's aspect ratio and at a clean multiple of its size; shrink with `para art fix`, never stretch.
- Change a cell only by deciding it in `CHOICES.md`; later changes cost every asset in that class.

## Ledger before any paid call

`games/<game>/art/LEDGER.md`: one line per generation: date, asset, class, tool, cost if known. Write the line **before** the call. Ask the friend before any call that spends their credits, and say how many you plan to make.

## Clean up and check

For each imported PNG in `games/<game>/art/raw/`:

1. `tmp/para art fix games/<game>/art/raw/<name>.png --cell WxH --out games/<game>/assets` (add `--pivot bottom` for standing characters; `--key RRGGBB` if it has a flat background colour). It also writes the `<name>.art.toml` sidecar.
2. `tmp/para art lint --failing games/<game>/assets` (failing rows only). Fix what it names or ask the friend if the look must change. Run the full `tmp/para art lint games/<game>/assets` table (one row per sprite) only when the friend asks or when comparing the whole set.
3. `tmp/para art sheet games/<game>/assets --out tmp/contact-<game>.png` and show it.
4. Wire it in as a normal ticket for the builder (`paraloop/render2d.loadSheet`); the builder is the only one to edit code.

`para art --help` lists all flags.

## Review page for visual picks

Only for look choices. Write `games/<game>/review/<topic>.html`, static, no server, no downloads:

- one block per option: the image at **game size** (`image-rendering: pixelated`), a label, the recommended option marked;
- the recommended option preselected (radio buttons);
- a "Copy my picks" button that puts one line on the clipboard, such as `art picks: look=B, ship=A`;
- open it for the friend with `xdg-open` (Linux), `open` (macOS) or `start` (Windows), and ask them to paste the line back into chat.

Record the answer in `CHOICES.md` as for any choice. Everything that is not a visual pick stays in chat.
