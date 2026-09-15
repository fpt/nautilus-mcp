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
| `config.rs` | TOML, parsed here and handed to Swift as JSON — Swift has no parser and this project has no Swift dependencies. |
| `nautilus.udl` | UniFFI interface definition. |

The FFI surface is **generic on purpose**: `tools()` + `call(name, args_json)`.
Adding an Android primitive needs no `.udl` change and no regenerated bindings.

### Swift targets (`swift/Sources/`)

| Target | Purpose |
|---|---|
| `NautilusMcp` | Executable. Argument parsing and the stdio loop — nothing else. |
| `NautilusKit` | MCP protocol (`MCPServer`), the tool protocol, the `FrameStore`, and every tool implementation. Where the work is, and what the tests cover. |
| `BrowserAX` | Reading a browser window through Accessibility. Read-only: it drives nothing, and there is no `BrowserCDP` beside it any more. |
| `ScreenCapture` | WindowManager / OCR / ObjectDetector, plus `ScreenPerception`. macOS only. |
| `TTS` | AVSpeechSynthesizer wrapper behind the `say` tool, plus the per-sentence language detection it needs — see **Configuration**. |
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

**`macos_permissions` is the deliberate exception**, and is always present. The
rule above has a blind spot: a tool that removed itself is indistinguishable,
from the far side of the protocol, from one that never existed. The reason is
logged — to **stderr**, which no MCP client displays and no model can read — so
"why can I not capture the screen?" had no answer available to the thing asking.
This tool exists precisely so absence can be explained, and it works whether or
not anything is granted.

```
macos_permissions → {
  "permissions": {
    "accessibility":    {"granted": false, "affects": ["browser_observe"],
                         "effect": "tools_removed_from_list",
                         "what_happens": "…kAXErrorAPIDisabled (-25211)…",
                         "how_to_grant": "System Settings → … add Terminal, then restart it."},
    "screen_recording": {"granted": true,  "affects": ["macos_capture_window", …]}
  },
  "grant_belongs_to": {"application": "Terminal", "bundle_id": "com.apple.Terminal", …},
  "startup": ["browser tools available (1): browser_observe over ax (Safari, Edge)…", …]
}
```

**The two grants do not behave the same way, and the report says which applies.**
This is easy to get wrong, and was: a first version claimed uniformly that
tools needing a grant are absent from `tools/list`.

| | without the grant |
|---|---|
| Accessibility | `browser_observe` is **removed** — `makeBrowserTools` returns nothing |
| Screen Recording | the `macos_` tools are **still listed and fail when called** — they are built unconditionally |

The Accessibility row used to carry a wrinkle, and no longer does: there were
once two browser tool groups gated differently, the recorder going
unconditionally while the control tools survived on a CDP endpoint. Both groups
are gone. Accessibility now gates exactly one tool, and gates it by removal —
which is a simpler thing to report and a simpler thing to get right.

**It names the application the grant belongs to**, which is the single most
useful thing in the reply. The grant is not `nautilus-mcp`'s; it belongs to
whatever launched it. Telling someone to add `nautilus-mcp` to the Accessibility
list sends them looking for a row that will never appear. The launcher is found
by walking up the process tree to the first real application — an approximation
of what TCC calls the responsible process, close enough to name the right row,
and reported as a best guess rather than asserted.

**`startup` carries the reasons the server recorded as it assembled itself** —
which browser backends came up, why a device is missing, whether the on-device
model exists — rather than re-deriving guesses at call time.

`request` shows the system prompt and `open_settings` opens the pane; both are
visible to the user, so both are opt-in. macOS shows the Screen Recording prompt
**once per application, ever** — if it was declined before, nothing appears and
Settings is the only route, which is why the reply always names the pane too.
Accessibility takes effect live; Screen Recording needs a restart.

### Protocol version is negotiated, not asserted

`initialize` echoes back the revision the client asked for when it is one we
speak (2025-06-18, 2025-03-26, 2024-11-05), and offers ours otherwise. The
server implements `initialize`, `tools/list` and `tools/call`, which are
compatible across all three, so agreeing is honest rather than optimistic.

Answering with a fixed version regardless of the request is legal but
unfriendly, and a client may simply give up — codex asks for 2025-06-18.

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

## Configuration

Optional, and TOML. Read from `--config <path>`, else `$NAUTILUS_CONFIG`, else
`~/.config/nautilus/config.toml` if it is there. `config.example.toml` in the
repo is a copyable starting point.

```toml
[tts]
rate = 0.5              # defaults, for any language
volume = 1.0

[tts.en]
voice = "com.apple.voice.enhanced.en-US.Ava"

[tts.ja]
voice = "com.apple.voice.enhanced.ja-JP.Kyoko"
rate = 0.45             # Kyoko reads a little fast at the shared default
```

Sections under `[tts]` are keyed by **bare language code**, which is what
detection returns. Everything is optional and inherits from `[tts]`; `--voice`
still works and beats the file, because a flag typed just now should win over a
file written last month.

**An explicit path that is missing or malformed refuses to start**, while a
missing default path is simply the normal case. Naming a path and silently being
given defaults because of a typo is the failure that wastes an afternoon. The
parser's own message comes through, line and column included:

```
nautilus-mcp: …/bad.toml: TOML parse error at line 1, column 5
  |
1 | [tts
  |     ^
invalid table header
```

An empty `NAUTILUS_CONFIG` means unset, not "a file named nothing" — that is how
a shell says "ignore it". Unknown keys are ignored rather than rejected, so a
config written for a later version still starts this one. What was loaded is
logged at startup, because a config that is quietly not in effect is the thing
worth preventing.

**TOML is parsed by the Rust core and handed over as JSON.** Swift has no TOML
parser and this project carries no Swift package dependencies; a hand-rolled
subset parser would quietly reject valid TOML the day somebody writes an array.
Same reasoning as the PNG codec, for a milder reason — there Swift's own library
is broken, here it simply does not have one.

### `say` picks a voice per sentence, because the wrong one is silent

`AVSpeechSynthesizer` does not fall back when the voice and the text disagree.
It returns normally, reports the utterance as finished, and plays **nothing**.
Measured by synthesizing to a buffer rather than to the speakers:

| | frames | peak amplitude |
|---|---|---|
| Japanese text, en-US voice | 256 | **0.0000** |
| Japanese text, ja-JP voice | 54,465 | 0.7649 |
| English text, en-US voice | 35,244 | 0.6831 |

A tool answering `Spoke 44 character(s).` while the room stays quiet is the same
class of failure as a stale frame: plausible output, no sign anything is wrong.
So the voice is chosen from the text, per sentence:

```
"Mixed sentence test. 設定ファイルは TOML です。Back to English now."
  → en-US:"Mixed sentence test." | ja-JP:"設定ファイルは TOML です。" | en-US:"Back to English now."
```

Sentences are the unit because that is where a voice change is inaudible; a
passage broken mid-clause would sound like a fault. Consecutive sentences in one
language are rejoined, so ordinary prose is still spoken as prose, and the caller
is not told the speech finished until the **last** utterance has — completing on
the first is how a bilingual sentence comes back half-said.

Detection is **script first, statistics second**. Kana settle Japanese outright,
where `NLLanguageRecognizer` asked about a short kanji-only phrase will happily
answer Chinese — the scripts genuinely overlap, and guessing wrong costs the
whole utterance. Han is deliberately left to the recogniser for that reason. A
sentence too short to identify inherits the previous one's language rather than
dropping to a default mid-paragraph.

**Nothing has to be configured.** With no file at all, the best *installed* voice
for the detected language is used — asking for the highest-quality `ja` voice
finds Kyoko (Enhanced) with nobody naming it, and with no hardcoded table of
language to locale. The config exists to pin a particular voice or slow one down.
A configured voice that is not installed is warned about at startup, rather than
failing silently at the first utterance.

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

## Browser reading — semantics, not pixels, and read-only

| tool | |
|---|---|
| `browser_observe` | the page as roles, names and ids |

That is the whole browser surface. The Android side must learn what a button
*looks like*, because a game draws its own widgets and publishes nothing about
them. A web page is the opposite: it already declares its roles and names, and
macOS surfaces them through Accessibility. So this speaks in
`button named "Sign in"`, and what it reads survives a site restyling its markup
as long as the accessible semantics hold. No per-site icon learning at all.

### The browser is read and never driven

There were four control tools here — `browser_activate`, `browser_set_value`,
`browser_scroll`, `browser_back` — plus a demonstration recorder
(`browser_record_*`, `browser_events_*`) and a Chrome backend over the DevTools
protocol. All of it is gone, deliberately, and not as a gap waiting to be
filled.

The reason is the same thing that made this browser worth reading in the first
place. Unlike a container-launched Chromium, the window this server can reach is
the **user's own**: their cookies, their sessions, their screen, and their
attention on it. That is exactly what makes a read valuable — nothing else can
answer what is behind their login — and exactly what makes a write the wrong
trade. An agent driving it is moving the pointer in the window a person is
looking at, on whatever an id happened to resolve to this time round. A misread
page costs a retry. A mis-click opens a link that cannot be un-opened.

So the rule is now blunt enough that nothing has to weigh it per call: **this
server does not click, type, scroll or navigate in a browser.** Anything that
must act on one belongs above this server, in a client where a person can see it
coming and stop it. The `say` tool is still here to ask them to do it.

What went with that decision, so it is not rediscovered as a bug:

| | |
|---|---|
| `BrowserBackend` | the protocol existed to hide *which* backend answered. With one reader left there is nothing to hide; `BrowserObserveTool` holds a `BrowserAXSession` directly |
| `page_epoch` / `stale_element` | an epoch existed so an id minted before a click could be refused afterwards. Nothing takes an id back now, so there is nothing to refuse — `id` is a label for saying which element you mean within one listing, and the payload no longer carries an epoch |
| the `logging` capability | declared only so the recorder could push events as they happened. With no producer left, `initialize` advertises `tools` alone and `logging/setLevel` answers `-32601`. Declaring a capability that can never emit is the same lie as advertising a tool that always fails |
| the `CGEventTap` | the recorder's half that saw clicks and scrolls. This process no longer installs a system-wide input tap at all |

`BrowserAXSession.source` still reports `"ax"` on every element. It is kept
because a reply that says where it got its facts stays readable if a second
reader is ever added beside this one.

### Chrome publishes nothing, and that is now simply a limit

Setting `AXManualAccessibility` — the documented way to ask Chromium to build
its web tree for an assistive client — returns `kAXErrorAttributeUnsupported`
(-25205) on Chrome 153. The attribute is not merely ignored; it is no longer
settable. The symptom is not an error but a plausible-looking answer:

```
browser_observe → 43 elements, every one of them toolbar or tab strip,
                  no AXWebArea, and url: null
```

That is the whole page missing while the tool looks like it worked — the same
class of failure as a stale frame. It used to be covered by CDP, which asks the
renderer directly and cannot be shut out that way; CDP went with the control
tools, because reading was never the reason it was there. **So Chrome pages are
unreadable, Safari and Edge answer properly, and both the startup summary and
the empty-result note say so out loud** rather than letting a toolbar-only reply
pass for a page.

The cost of the old arrangement is worth remembering if it is ever revisited:
Chrome since 136 refuses to open a debugging port for the default profile, so
the debugged Chrome was **not** the one holding your everyday logins unless
`--user-data-dir` pointed at a profile that did — which undercut the one
advantage this server has over a container.

### Accessibility, and what the grant does and does not buy

`browser_observe` needs Accessibility, granted to the application that
*launches* the server — the terminal or MCP client, not the browser, and not
`nautilus-mcp` itself — in System Settings → Privacy & Security → Accessibility.
The symptom when it is missing is `kAXErrorAPIDisabled` (-25211) on every read,
and the tool is left out of `tools/list` rather than advertised.

Worth saying plainly in the permissions report, and it is: the grant now buys
**reading only**. There is no tool here that a grant would let touch someone's
window. Accessibility takes effect live, so granting it and restarting the
server is enough — no logout.

### The web tree is built lazily

The first read after attaching returned 26 nodes — Safari's own toolbar and
nothing else — where a moment later the same window held 397 including 143
links. A thin result with no `AXWebArea` is therefore retried once rather than
reported as an empty page. (`AXManualAccessibility` is unsupported on Safari and
not required there.)

### The element list is the whole page

Scrolling does not change what `browser_observe` returns — measured, 78 elements
at the top of a page and the same 78 at the bottom. Accessibility publishes the
whole document, so **a long page needs no scrolling to read**, which is the
reason losing `browser_scroll` costs a reader nothing.

It does cost one thing, and it is worth being honest about it: scrolling used to
provoke lazily-loaded content, and measured, scrolling a GitHub page two
viewports took the count from 112 to 122. A page that loads on scroll now needs
the user to scroll it. Ask them, then observe again.

Element frames are in screen coordinates, so `include_frames` is what tells you
what is actually in view — the list itself covers the whole page either way.

### When to fall back to pixels

A canvas, a chart, a map or a WebGL view publishes no semantics — and so does
every Chrome tab. For those, `macos_capture_window` plus `image_ocr` is the
answer. The split mirrors the game side: a fast semantic path, a slow visual
one. Both are reads; neither touches anything.

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

# configuration (all optional)
nautilus-mcp --config ./config.example.toml
NAUTILUS_CONFIG=~/.config/nautilus/config.toml nautilus-mcp

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
│   ├── BrowserAX/       # Accessibility reader (Safari, Edge) + the element model
│   ├── ScreenCapture/   # WindowManager, OCR, ObjectDetector, ScreenPerception
│   ├── FoundationModelsKit/, AgentCore/, TTS/, Util/
│   └── NautilusBridge(FFI)/
├── scripts/gen_uniffi.sh
└── Makefile
```

## Troubleshooting

**An MCP client does not see the server at all**: check the installed binary
actually launches — `~/bin/nautilus-mcp --help; echo $?`. An exit of **137** is
SIGKILL, and the crash report will say `Taskgated Invalid Signature`.
Overwriting a binary that has already been run leaves the kernel holding a stale
ad-hoc signature for that path; every later launch is killed before it prints
anything, so the client sees a server that never answers. `make install`
re-signs for this reason; to fix a copy made some other way:

```bash
codesign --force --sign - ~/bin/nautilus-mcp
```

Nothing about the file gives this away — it is byte-identical to a working
binary and `codesign -v` calls it valid.

**"library 'nautilus_core' not found"**: `cd crates && cargo build --release`

**"no such module 'nautilus_coreFFI'"**: `bash scripts/gen_uniffi.sh`

**UniFFI checksum mismatch**: regenerate; the script copies for you.

**No `android_` tools**: check `adb devices`. An `unauthorized` device needs the
on-screen "Allow USB debugging" prompt accepted. The reason is logged to stderr
at startup.

**No `browser_observe`**: Accessibility is not granted, and the grant belongs to
the application that *launches* the server — your terminal, or the MCP client —
not to `nautilus-mcp` itself and not to the browser. Add that application in
System Settings → Privacy & Security → Accessibility and restart it. Because the
grant follows the launcher, switching MCP clients means granting again, while
reinstalling the server does not.

**`browser_observe` on Chrome returns only the toolbar**: that is Chrome, not a
bug. It publishes no page through Accessibility at all, and the DevTools-protocol
backend that used to cover it went with the control tools. Read the page in
Safari or Edge, or fall back to `macos_capture_window` plus `image_ocr`.

**Looking for `browser_activate`, `browser_scroll`, `browser_back`,
`browser_record_*`**: removed on purpose — see *The browser is read and never
driven*. This server does not act on a browser. Ask the user to do it (the `say`
tool is there for exactly that) and observe again afterwards.

**`say` runs but nothing is heard**: the voice does not match the language of
the text, and AVSpeechSynthesizer is silent rather than approximate in that
case. It should not happen now — the voice is chosen per sentence — but a voice
pinned in the config for the wrong language would do it. The startup log names
the config in effect, and a configured voice that is not installed is warned
about there too.

**No `ask_local_model`**: the on-device model is unavailable (not Apple silicon,
or Apple Intelligence off). Logged at startup; the tool is simply absent.

**Screen capture returns nothing**: grant Screen Recording to the app that
launched the server, then restart it. `macos_permissions` reports whether it is
granted and names that application. Note these tools are **not** removed when
the grant is missing — they stay in the list and fail on the way to
`SCShareableContent`, which every one of them goes through.

**Anything is missing and it is not obvious why**: call `macos_permissions`. It
is always present, reports both grants, and hands back the startup reasons that
otherwise only reach stderr.

## What is deliberately not here

The agent (app-server client, backend spawning, goals, skills, conversation
memory), the Windows C# frontend, speech recognition, and the voice REPL. They
live in the history of [voice-agent](https://github.com/fpt/voice-agent).

Browser **control** and the demonstration recorder were here and were removed —
`browser_activate`, `browser_set_value`, `browser_scroll`, `browser_back`,
`browser_record_*`, `browser_events_*`, the `BrowserCDP` target and the
`CGEventTap` with them. The reasoning is in *The browser is read and never
driven*; the code is on the `backup/browser-cdp-and-control` branch if any of
the measurements behind it are ever needed again.
