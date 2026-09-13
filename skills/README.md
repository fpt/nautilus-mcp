# Discovered skills

Composite, app-aware procedures discovered by driving an app through
nautilus-mcp's primitives.

**These are not part of the server, and the server knows nothing about them.**
nautilus-mcp deliberately stops at perception and body — observe, crop, OCR,
diff, tap, swipe, key. Naming a button "the build menu" is semantics, and
semantics live here, above the server. That boundary is what lets the same
server drive a different app unchanged; these files are what makes it *useful*
for one specific app.

A client (an agent, a script) reads these. Nothing in `crates/` or
`swift/Sources/` ever does.

## How they were produced

By exploration, not by reading documentation: observe → act → observe → verify,
keeping whatever worked. Each skill records the *verification signal* that
proves it worked, because in this game almost nothing reports its own success —
`android_tap` returns the same whether it hit a button or bare ground.

## Files

| file | |
|---|---|
| `call-of-dragons.yaml` | Skills for コール オブ ドラゴンズ (`com.farlightgames.samo.gp.jp`) |
| `visual-prototypes.yaml` | App-agnostic: teaching and maintaining learned appearances |
| `tools/icons.py` | Keeping the prototype store current — see below |

## Keeping icons up to date

A learned appearance is only useful while it still matches the screen. Game
updates re-skin controls, and some controls look different depending on their
own state, so the store needs checking.

```bash
cd skills/tools
uv run icons.py check farlight_cod        # after a game update
uv run icons.py learn farlight_cod/march_button --region 0.80,0.84,0.87,0.89
uv run icons.py learn farlight_cod/march_button --region <look-alike> --negative
uv run icons.py shot screen.png           # to read coordinates off
```

It is a plain MCP stdio client over `swift/.build/release/nautilus-mcp`, so it
can do nothing an agent could not do by calling the tools itself. Stdlib only;
the PEP 723 header just pins the interpreter for `uv run`.

**Read the drift, not the score.** Scores are relative to what sits behind an
element — a control over a busy animated corner scores ~0.30 while one on a flat
panel scores ~0.47, and both are exact. `check` therefore judges by how far a
match landed from where it was taught.

## Reading a skill

- `verified: true` means it was executed end to end and the stated signal was
  observed. `partial` means the path is known but the run was not completed;
  the `blocked_by` field says why.
- Coordinates are **normalized 0.0–1.0**, measured in landscape on a
  1336x752 display. They should transfer across resolutions; they will not
  survive a UI-layout change.
- `locate_by: ocr` on a step means **do not trust the coordinate** — the
  element moves between runs, so find it by text each time. Where a skill says
  this, it is because a fixed coordinate was observed to fail.
