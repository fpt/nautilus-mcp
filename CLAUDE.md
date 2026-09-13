# nautilus-mcp — Developer Guide

## Overview

A **headless MCP server**. It exposes macOS perception (screen capture, OCR,
object detection, speech, the on-device model) and Android device control (over
`adb`) to any MCP client, over stdio.

It runs **no inference of its own** beyond Apple's on-device model, and drives no
agent. The client decides what to do; nautilus-mcp only says what the machine can
do and does it.

- **Platform**: macOS 26+
- **Swift**: swift-tools-version 6.1, `.swiftLanguageMode(.v5)` on all targets
- **Rust**: workspace in `crates/`, one member — the `nautilus_core` cdylib

## Architecture

```
MCP client  ──stdio, line-delimited JSON-RPC 2.0──>  NautilusMcp (main.swift)
                                                          │
                                                     NautilusKit
                                          ┌───────────────┼───────────────┐
                                   macOS tools         say / model      AndroidTool
                                   ScreenCapture       TTS / FMK             │
                                   (AppKit, Vision)                     UniFFI
                                                                             │
                                                                    nautilus_core (Rust)
                                                                             │
                                                                         adb → device
```

**Swift owns the main loop.** `WindowManager` is `@MainActor` (ScreenCaptureKit
and AppKit need it), so the server loop runs there and stdin is read off-thread.
Rust contributes the Android controls and nothing else.

> This is the reverse of voice-agent, where Rust owned the tool registry and
> proxied each macOS tool back to Swift over a polled channel bridge. Inverting
> it **deleted** that bridge — no channels, no polling, no per-tool result
> routing — because Swift now calls its own frameworks directly.

### Rust crate (`crates/lib`, `nautilus_core`)

| File | Purpose |
|------|---------|
| `lib.rs` | UniFFI exports: `AndroidController` (bind a device, list tools, call one by name), `ToolSpec`/`ToolOutput`, `NautilusError`. |
| `android/device.rs` | adb transport: rotation-aware geometry, normalized→pixel, timeouts. |
| `android/tools.rs` | The `android_*` primitives as `ToolHandler`s. |
| `tool.rs` | `ToolHandler` / `ToolResult`. |
| `image.rs` | `ImageContent`, plus the PNG codec Swift borrows — see **ImageIO is unusable** below. |
| `nautilus.udl` | UniFFI interface definition. |

The FFI surface is **generic on purpose**: `tools()` + `call(name, args_json)`.
Adding an Android primitive needs no `.udl` change and no regenerated bindings.

### Swift targets (`swift/Sources/`)

| Target | Purpose |
|---|---|
| `NautilusMcp` | Executable. Argument parsing and the stdio loop — nothing else. |
| `NautilusKit` | MCP protocol (`MCPServer`), the tool protocol, the `FrameStore`, and every tool implementation. Where the work is, and what the tests cover. |
| `ScreenCapture` | WindowManager / OCR / ObjectDetector, plus `ScreenPerception`. macOS only. |
| `TTS` | AVSpeechSynthesizer wrapper, behind the `say` tool. |
| `FoundationModelsKit` | Apple's on-device model, in-process, behind `ask_local_model`. |
| `AgentCore` | Protocols `FoundationModelsKit` and `ScreenPerception` are written against (`EnvironmentPerception`, `AgentBackend`). Kept for them; nothing else uses it. |
| `Util` | Just the logger now. |
| `NautilusBridge(FFI)` | Generated UniFFI bindings. The Rust cdylib dependency stops here. |

## Invariants worth knowing

### stdout is the transport

Anything printed to stdout corrupts the MCP stream. This is not hypothetical:
the TTS logger announced its chosen voice at startup and put a non-JSON line in
the middle of the protocol.

Two defences, because auditing every `print` in every dependency does not scale:

1. `Util.Logger` writes **every** level to stderr.
2. `claimTransport()` in `main.swift` takes a private `dup` of fd 1 for the
   protocol, then points fd 1 at stderr — so stray output is harmless by
   construction.

Diagnostics go to stderr. `--help` prints before the swap; `--list-tools` writes
through the transport handle, because that output really is stdout.

### A tool that is present is a tool that works

`MCPServer.init(optionalTools:)` takes `[MCPTool?]` and drops the absent ones. A
Mac without Apple Intelligence does not advertise `ask_local_model`; with no
device attached there are no `android_` tools. Advertising a tool that always
fails is worse than omitting it — a model reads the list as what the machine can
do and will keep choosing it.

### Tool failure vs. protocol error

MCP draws a line, and so do we:

| | |
|---|---|
| a tool ran and failed | `{content, isError: true}` — the model reads it and tries something else |
| the request was never valid | JSON-RPC error: unknown tool `-32602`, unknown method `-32601`, bad JSON `-32700` |

`ToolFailure` and `ProtocolFailure` are separate types so this cannot be got
wrong by accident.

### Requests are handled one at a time

MCP permits pipelining. Every tool here ultimately touches a single shared
resource — one screen, one device, one speaker — so serializing is the honest
behaviour, not a limitation to work around.

## Perception: frames, regions, coordinates

`android_observe` and `macos_capture_window` both mint a **`frame_id`** and keep
the pixels in a [`FrameStore`] — a ring buffer of the last 8. The image tools
then address a frame by id (omit it for the most recent), so a loop like

```
observe → regions → crop → ocr → tap → observe → diff
```

pushes the picture across the protocol only when a caller actually needs to look
at it. A game screenshot is over a megabyte of base64; sending it four times for
one decision is the thing the cache exists to stop.

| tool | |
|---|---|
| `image_ocr` | text + boxes; narrow with `region`/`region_id` for speed and accuracy |
| `image_crop` | cut a region out as a **new frame**, and show it |
| `image_regions` | candidate areas: `text_like`, `rectangle`, `salient` |
| `image_diff` | what changed between two frames |
| `android_tap_region` | tap a region's centre — sugar over `android_tap` |
| `visual_learn` | remember how an element looks, as an edge sketch + feature print |
| `visual_find` | find a learned element again, without OCR |
| `visual_list` | what has been learned so far |
| `android_read_text` | capture **and** OCR in one call — cannot be stale |
| `android_look_for` | capture **and** locate a learned element — cannot be stale |

They are source-agnostic: the same four work on an Android screenshot and a
macOS window.

### Every box is in root-frame coordinates

This is the invariant the whole design rests on. A crop is itself a `Frame` that
remembers, in `originRect`, where it sits in the root frame — so a hit found
inside a crop of a crop still reports **where it is on the screen**, never where
it is in the crop.

Get this wrong and nothing downstream can interpret a box: OCR a crop of the
bottom-right corner, return `[0.3, 0.2, 0.7, 0.8]`, and no caller can say whether
that is crop space or screen space. Because Android input is normalized against
the same frame, `ocr → bbox → tap` composes with **no conversion step at all**.

Verified against the live game: a 147x48 crop at root `x 0.890-1.0,
y 0.052-0.116`, OCRed, returned boxes at `x 0.910-0.988, y 0.076-0.094` — root
coordinates. Crop-local ones would have read about `0.17, 0.38`.

### Visual recognition — OCR discovers, appearance recognises

`image_ocr` is for working out what something *is*, once. After that,
`visual_learn` remembers how it looks and `visual_find` finds it again, with no
dependence on font, language, or the scene behind it.

That matters here: OCR of this game's stylized Japanese read ペット as ミツ at
0.3 confidence, while the learned icon matches to within a few pixels.

```
first sighting :  observe -> image_ocr -> "this is 進軍" -> visual_learn
afterwards     :  observe -> visual_find -> tap -> verify
uncertain      :  fall back to image_ocr, then visual_learn the new look
```

**What is stored.** Under `resources/<set>/<name>/`: the crop it was taught
from, a **64x64 monochrome edge sketch**, and `prototype.json`. Edges rather
than pixels, because a game button sits on a 3D scene that differs every frame,
its fill animates, badges overlap it, and it rescales with resolution — the
outline survives all of that. The PNGs are written so a human can look at what
the matcher believes; matching itself reads only the JSON.

**How a match is found**, in two stages:

| | |
|---|---|
| propose, cheaply | slide a window of the prototype's aspect over one luminance buffer, scoring by normalized cross-correlation — array arithmetic after a single CoreGraphics draw. 24 survive, because the sweep lands on a grid and a real match once sat seventh, below a shortlist of six |
| align, locally | nudge each survivor by a few pixels and scales. The refined box is offered **alongside** the coarse one rather than replacing it: refinement maximizes *shape* while the verdict is mostly *feature print*, and deciding on a proxy cost a known-good match 0.470 → 0.388 |
| confirm, expensively | compare the finalists with `VNGenerateImageFeaturePrintRequest`, which is what distinguishes this button from its neighbour |

Hard negatives are subtracted at the end, because a game's icons resemble each
other and "similar enough" is not "the right one".

**`VNClassifyImageRequest` is the wrong API** for this and was tried: asked
about a UI button it answers `blue_sky 0.30` — it classifies natural images
into a fixed taxonomy and knows nothing of an application's widgets. The
feature print is the right one: the same button rescaled scores 0.19, two
different buttons about 1.0.

**A prototype records the size it was learned at**, relative to the frame, and a
search sweeps around that. Guessing the size from the search region's own width
fails as soon as that region is an odd shape — a wide, short strip made every
candidate window larger than the icon being looked for, and nothing matched.

**Read the margin, not the score.** Scores are relative. Measured on the game's
six-icon menu row, the taught icon scored 0.383 and every other icon
0.082-0.159, so a good match is ~0.3-0.5 and the default floor is 0.25. A high
floor throws away real hits: 0.35 rejected a match that had localised to within
three thousandths of the right spot.

**A control can change appearance with its own state.** The lower-right menu
emblem scored 0.436 with its menu open and 0.11 with it closed — the same
button, a different picture. Learn both looks into one prototype.

### Observations have a lifetime

A frame captured before an action describes a world that no longer exists.
Reading it afterwards returns numbers that look entirely plausible and are
simply wrong, which is exactly how it misleads — it was got wrong three times in
one session by the author of the tools.

The fix is not to remember harder. `FrameStore` keeps an **interaction epoch**:
every device action bumps it, every frame records the value it was captured at,
and reading an older frame is refused with a machine-readable explanation.

```json
{"error": "stale_frame", "frame_id": "f12",
 "captured_epoch": 31, "current_epoch": 32, "actions_since": 1,
 "recovery": "…capture again with android_observe, or use a tool that captures for you…"}
```

Three details decide whether this actually helps:

- **Anything that is not `android_observe` or `android_info` advances the
  epoch.** Defaulting to "changes the world" means a primitive added to the Rust
  side later is stale-safe without anyone remembering to list it.
- **`android_wait` advances it too.** Animations play and creatures walk while
  nothing is being pressed.
- **`image_diff` is exempt**, because comparing before against after is its
  whole purpose. It asks for `allowStale`; nothing else does.

### An omitted `frame_id` means the screen, not the last thing you made

`latestCapture` skips crops. Resolving to the most recent *frame* would redirect
`observe → crop → crop → ocr` onto the second crop, which reads as a tool
inexplicably failing to see something plainly on screen. `latest` still exists
and is almost never what a caller wants.

### Acting is a primitive; perceiving is an atomic query

`android_read_text` and `android_look_for` capture first and then answer. They
are not per-app composites — nothing in them knows what a march or a resource
node is — they are the same perception the primitives offer with the capture
folded in, so that "what does the screen say?" stops being bookkeeping.

The primitives remain for when a caller wants several readings of one frame, or
wants to diff two.

### `image_regions` says where, never what

It reports `text_like` / `rectangle` / `salient` and stops there. Vision
proposes; OCR and the caller's own eyes decide. A server that answered
"barracks" would be guessing about an application it knows nothing about, and
would stop the caller looking for itself. The division is:

```
Vision Framework = proposal generator
OCR              = symbolic reader
the caller       = semantic classifier
```

Composite, app-aware tools (`find_and_click_text`, `train_archer`) belong
**above** this server, not in it. That boundary is what lets the same server
drive a different application unchanged.

### ImageIO is unusable — PNG coding goes through Rust

`ImageCoding` (Swift) delegates PNG encode and decode to the Rust core's `png`
crate. Swift has ImageIO and **cannot use it here**: its codecs fault with

```
SIGBUS  EXC_ARM_DA_ALIGN at 0x0bad4007   <- the top frame IS that address
  ImageIO  PNGWritePlugin::writePrologue / PNGReadPlugin::InitializePluginData
```

in any ordinary compiled binary — encode *and* decode, PNG *and* TIFF — while
working inside Apple-signed hosts. Established by elimination: it survives a
reboot, is not the data (a 64x64 image we generate ourselves faults on encode),
is not the Rust dylib (a bare `swiftc` binary faults identically), and is not
fixed by re-signing with a hardened runtime or `disable-library-validation`.

Two consequences worth remembering:

- **No test can catch a regression here**, because `xctest` is Apple-signed and
  ImageIO works inside it. The failure mode is a process crash, not an
  exception, so it takes the MCP session with it. Verify image paths by running
  the built binary, never by trusting a green suite.
- Everything else is fine: `CGImage` built from raw bytes is pure CoreGraphics,
  and Vision reads it happily. Only the file codec is broken, so only the file
  codec moved.

If ImageIO is ever healthy on a target machine, `ImageCoding` is the single
place to revisit — nothing else touches image files.

## Android controls

Nine general primitives, with **no per-app code anywhere**: the intent is that
composite skills ("open the build menu", "find the selected unit") are
*discovered* on top of them rather than hand-written per application.

```bash
nautilus-mcp --android auto        # the only attached device
nautilus-mcp --android <serial>    # a specific one; ADB overrides the binary
nautilus-mcp --android off         # leave them out
```

Drive them without the server:

```bash
cd crates && cargo run --example android_probe -- tools     # what the model reads
cargo run --example android_probe -- observe /tmp/s.png
cargo run --example android_probe -- tap 0.908 0.537
```

### Coordinates are normalized, and rotation is read

Every model-facing coordinate is `0.0..=1.0`, never pixels: a discovered skill
recorded as `tap(0.91, 0.54)` survives a different device and a rotation;
`tap(1213, 404)` does not. A pixel value passed where a fraction belongs is
**rejected**, not clamped — clamping to the edge reads as "the tap missed"
forever.

`wm size` reports the *panel*, not the display. On a landscape handheld
(Retroid Pocket 3+, rotation 1) it answers `752x1336` while the framebuffer —
and every coordinate `input tap` accepts — is `1336x752`. Trusting it transposes
every tap. Geometry therefore comes from `dumpsys window displays`' `cur=`
field, which is already rotation-applied; `wm size` is only a fallback, with the
swap applied by hand. `android_observe` compares the PNG's IHDR against the
geometry it believed and warns if they ever disagree.

Verified on-device: screenshot 1336x752, and `(0.908, 0.537)` → pixel
`(1213, 404)` opened the icon that sat at that spot in the screenshot.

### `am start`, not `monkey`

`monkey -p <pkg> 1` is the usual one-liner and is **not** used. Against a large
game it hung for over 20s, survived the adb client being killed (killing adb
does not kill the on-device process — it was left orphaned in `futex_wait`), and
never started the app. `launch_app` resolves the launcher activity with
`cmd package resolve-activity --brief` and starts it explicitly: 143ms.

Every `adb` invocation runs under a 20s timeout for that reason — a wedged adb
must fail the tool call, not hang the server.

### Known limits

- **No hover.** `adb shell input` has no pointer, so a
  hypothesis → hover → tooltip → OCR loop is not expressible; `android_long_press`
  is the nearest substitute. scrcpy's control socket is what unlocks a real
  pointer and is the natural second transport behind `Device`.
- **Latency.** Measured on a Retroid Pocket 3+: `input` ~650ms (Android's `input`
  binary starts a JVM per call), screenshot ~400ms, geometry ~80ms. The scrcpy
  control socket sends a binary message instead and would make input ~free.
- **ASCII only** for `android_text`; Japanese needs an IME such as ADBKeyboard.
  Non-ASCII is rejected with that explanation rather than silently typing
  nothing.
- **No hover-driven inspection**, per the first bullet; crop, OCR, region
  proposal and diff are all present now, on both sources.

## Build & Run

```bash
make build          # Rust cdylib + Swift server
make test           # both suites
make install        # ~/bin/nautilus-mcp
make list-tools     # what this machine offers

# after changing crates/lib/src/nautilus.udl
make gen-uniffi
```

Exercise the protocol by hand — it is just lines of JSON:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | swift/.build/debug/nautilus-mcp
```

## Project Structure

```
nautilus-mcp/
├── crates/lib/src/      # nautilus_core: android controls + UniFFI surface
│   ├── android/         # device.rs (adb transport), tools.rs (primitives)
│   └── nautilus.udl
├── crates/lib/examples/ # android_probe.rs — drive the tools without the server
├── swift/Sources/
│   ├── NautilusMcp/     # executable: args + stdio loop
│   ├── NautilusKit/     # MCP server + tools
│   ├── ScreenCapture/   # WindowManager, OCR, ObjectDetector, ScreenPerception
│   ├── FoundationModelsKit/, AgentCore/, TTS/, Util/
│   └── NautilusBridge(FFI)/
├── scripts/gen_uniffi.sh
└── Makefile
```

## Troubleshooting

**"library 'nautilus_core' not found"**: `cd crates && cargo build --release`

**"no such module 'nautilus_coreFFI'"**: `bash scripts/gen_uniffi.sh`

**UniFFI checksum mismatch**: regenerate; the script copies for you.

**No `android_` tools**: check `adb devices`. An `unauthorized` device needs the
on-screen "Allow USB debugging" prompt accepted. The reason is logged to stderr
at startup.

**No `ask_local_model`**: the on-device model is unavailable (not Apple silicon,
or Apple Intelligence off). Logged at startup; the tool is simply absent.

**Screen capture returns nothing**: grant Screen Recording to the app that
launched the server, then restart it.

## What is deliberately not here

The agent (app-server client, backend spawning, goals, skills, conversation
memory), the Windows C# frontend, speech recognition, and the voice REPL. They
live in the history of [voice-agent](https://github.com/fpt/voice-agent).
