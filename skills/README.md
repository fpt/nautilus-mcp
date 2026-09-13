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
