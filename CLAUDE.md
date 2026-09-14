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

## Browser control — semantics, not pixels

| tool | |
|---|---|
| `browser_observe` | the page as roles, names and ids |
| `browser_activate` | press a button, follow a link, tick a checkbox |
| `browser_set_value` | put text in a field |
| `browser_scroll` | move the page: down, up, top, bottom |
| `browser_back` | go back in history |
| `browser_record_start` / `_stop` | watch what a **person** does in the browser |
| `browser_events_read` | read that back as a trajectory; waits for them to finish |
| `browser_events_clear` | start a fresh demonstration |

The Android side must learn what a button *looks like*, because a game draws its
own widgets and publishes nothing about them. A web page is the opposite: it
already declares its roles and names, and macOS surfaces them through
Accessibility for Safari and Chrome alike. So these speak in
`button named "Sign in"`, and a skill survives a site restyling its markup as
long as the accessible semantics hold. No per-site icon learning at all.

The backend is hidden: every element reports a `source` — `ax` for macOS
Accessibility, `cdp` for Chrome's DevTools protocol — so a skill does not know
or care which answered. `BrowserRouter` picks: Safari and Edge go to AX, Chrome
goes to CDP, and actions follow whichever backend served the last `observe`,
because the ids they carry were minted there. The container-based
`chromedp-container-mcp` is a separate project and is not wired in here —
nautilus drives the real browser window on screen, with its real cookies and
sessions.

### Chrome closed the Accessibility door, so Chrome gets CDP

Setting `AXManualAccessibility` — the documented way to ask Chromium to build
its web tree for an assistive client — returns `kAXErrorAttributeUnsupported`
(-25205) on Chrome 153. The attribute is not merely ignored; it is no longer
settable. The symptom is not an error but a plausible-looking answer:

```
browser_observe → 43 elements, every one of them toolbar or tab strip,
                  no AXWebArea, and url: null
```

That is the whole page missing while the tool looks like it worked — the same
class of failure as a stale frame, and the reason the startup log now says so
out loud when no CDP endpoint is around.

CDP asks the renderer directly and cannot be shut out that way. It is also
better behaved for actions: scrolling and history are function calls inside the
page rather than synthesized keystrokes, so **nothing is brought to the front
and nothing depends on focus** — the opposite of the AX path, which must raise
the window and fail loudly when it cannot.

```bash
# Chrome must be started with the port. Since Chrome 136 it also refuses to
# open it for the default profile, so it needs its own --user-data-dir.
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir="$HOME/.nautilus-chrome"

nautilus-mcp --chrome-cdp auto   # probe 127.0.0.1:9222 (default)
nautilus-mcp --chrome-cdp 9333   # a different port
nautilus-mcp --chrome-cdp off    # Accessibility only
```

That profile requirement is the real cost, and it is worth being honest about:
the debugged Chrome is **not** the one holding your everyday logins unless you
point `--user-data-dir` at a profile that does.

**Which window, and the limit of knowing.** `/json/list` will not say: measured,
activating a different window left its order completely unchanged, so position
is creation order and carries no information at all.

Asking the pages gets closer, but `document.visibilityState` answers a smaller
question than it looks. It is `visible` for the active tab of **every** window —
it separates tabs *within* a window and says nothing about which window is in
front. Trusting it alone is what made `browser_observe` read example.com while
iana.org sat frontmost, silently and with no sign anything was wrong.

`document.hasFocus()` is true in exactly one page and is the real signal — but
only while Chrome is the frontmost application. The normal case here is a caller
working in a terminal with Chrome behind it, and then **every page answers
false** and the front window is genuinely unknowable from inside the browser.

So the picker has three rules, in order, and the third one owns up:

| | |
|---|---|
| a page reports focus | drive it — this is certain |
| otherwise, one is already being driven | stay there; a caller mid-task means the window they have been working in |
| otherwise | take a visible one, and report `window_ambiguous` naming the others |

The warning fires once, on the uncertain first pick, and stays quiet afterwards
because the second rule has taken over. Clicking the window you want is the
recovery: focus then decides it, and the choice sticks.

Every target is probed on every call. The earlier version cached the decision to
save websocket handshakes, which is what let a stale choice survive a window
switch — the handshakes are local and cost less than the read they precede.

**A document between pages reads as an empty one.** `activate` returns when the
click is delivered, so the next call can land while `document.body` is still
null: measured here, a click through to iana.org observed as `count: 0` and
helpfully advised falling back to OCR on an ordinary HTML page. Both backends
now wait and look again rather than believe the first thin result — it is the
same hazard as Safari's lazily-built tree, and it gets the same answer.

**Accessibility permission is required for the AX backend**, granted to the
application that launches the server — the terminal or MCP client, not the
browser — in System Settings → Privacy & Security → Accessibility. The symptom
when it is missing is `kAXErrorAPIDisabled` (-25211) on every read.

Either backend is enough to advertise the tools: a Mac with no grant but a
Chrome on the debug port still gets browser control, and a Mac with the grant
and no port still drives Safari. Only when neither can serve are the tools
absent, with the reason logged at startup.

**The web tree is built lazily.** The first read after attaching returned 26
nodes — Safari's own toolbar and nothing else — where a moment later the same
window held 397 including 143 links. A thin result with no `AXWebArea` is
therefore retried once rather than reported as an empty page.
(`AXManualAccessibility` is unsupported on Safari and not required there — and
no longer settable on Chrome either, which is why Chrome has its own backend.)

### Element ids expire, exactly like frame ids

A page re-renders constantly, so a handle from before a click may now point at
something else. Same lesson as the frame store, same shape of fix: the session
keeps a `page_epoch`, every action bumps it, and acting on an id from an older
observation is refused with `{"error":"stale_element", …}` and a recovery hint.
Selenium calls this `StaleElementReferenceException`.

### The element list is the whole page

Scrolling does not change what `browser_observe` returns — measured, 78 elements
at the top of a page and the same 78 at the bottom. Accessibility publishes the
whole document, so **a long page needs no scrolling to read**.

`browser_scroll` is therefore for two other things: making something visible for
a pixel fallback, and provoking lazily-loaded content. That second one is real —
scrolling a GitHub page two viewports took the count from 112 to 122.

Element frames are in screen coordinates, so `include_frames` is what tells you
what is actually in view. It is also how scrolling was verified: 80 of 98 shared
elements moved up by 1360 points, two viewports' worth.

### Input goes to two different places

This decides which mechanism each action uses:

| | routed by | so |
|---|---|---|
| scroll wheel | **position** | works without focus; lands on the page under the cursor |
| keystrokes | **focus** | needs the browser frontmost |

Hence `browser_scroll` up/down uses wheel events — Page Down would go wherever
the caret happens to be, and with the cursor in a search field it scrolls
nothing while looking like it worked. `top`/`bottom` and `back` need keys, so
they raise the browser first and fail loudly if they cannot.

**Raising it uses `AXFrontmost`, not `NSRunningApplication.activate()`.** macOS
stops a background process taking focus, so `activate()` returns successfully
and does nothing: the browser stays behind, keystrokes land in the terminal, and
`browser_back` silently fails. `AXFrontmost` is permitted to a process that
already holds Accessibility.

**Back is ⌘[, not ⌘←.** ⌘← was the first guess, on the theory that arrow keys
avoid keyboard-layout trouble. Safari does not bind it. The keystroke was
arriving the whole time — ⌘L focused the address bar in the same test — the
shortcut was simply wrong.

## Recording a demonstration

`browser_observe` answers "what is on the page now". The more valuable question
is "what did the user just do", and the recorder answers that one. Someone
working in their own Safari — already signed in, already past the SSO redirect
and the passkey prompt — is demonstrating a task at no cost to anyone, and the
result is the raw material a skill is distilled from.

This is what a container-based browser cannot do at all. A throwaway Chromium
has no cookies, no session and no person in it, so it can neither be shown a
task nor reach anything behind a login. Here the person and the agent share one
browser, so the demonstration and the replay happen in the same place.

```
browser_record_start → the user does the task → browser_events_read(wait_seconds: 120)
```

### macOS reports the consequences, not the causes

Measured against Safari, and it decided the whole design:

| | |
|---|---|
| navigation | `AXLoadComplete`, and `AXURL` on the web area is the real URL |
| page title | `AXTitleChanged` on the window, twice per load |
| typing | `AXValueChanged` carries the text as it is typed |
| moving between fields | `AXFocusedUIElementChanged`, with role and name |
| **a click** | **nothing at all** — Accessibility has no input event |
| **a scroll** | **nothing at all** |

So Accessibility alone records what happened *to* the page and misses what the
person did. A click that navigates shows up only as the navigation; one that
opens a menu, ticks a box, or does nothing is invisible.

A `CGEventTap` supplies exactly the two that are missing, and
`AXUIElementCopyElementAtPosition` turns a click at (411, 341) back into
`link "Learn more"`. **The tap knows the verbs; Accessibility knows the nouns
and the effects.**

The hit test answers with the *deepest* node, which for a link is its
`AXStaticText` child — measured, clicking "Learn more" resolved to the label,
not to the link that actually navigated. So the resolver climbs to the nearest
actionable ancestor.

### It is deliberately not a keylogger

A session event tap can see every keystroke in every application, and this one
does not ask for them: it subscribes to mouse-down and scroll-wheel only, which
is the smallest set covering what Accessibility cannot see. Typed text comes
from `AXValueChanged` on Safari's focused field instead — already scoped to the
browser, already naming the field it went into, and worth more to a trajectory
than a stream of key codes.

Two further limits for the same reason: recording starts on an explicit call and
stops on another, and the value of a secure text field is never stored, only the
fact that something was typed into one.

### Focus is what makes the stream readable

Raw Accessibility notifications are nowhere near a trajectory. Measured here:
pressing ⌘L and typing four characters produced **about eighty**
`AXValueChanged` in three hundred milliseconds — every suggestion row in the
address-bar dropdown, every favicon beside one, the headings "Google
Suggestions" and "Top Hit".

One rule removes almost all of it: **report a value change only for the element
that currently has keyboard focus.** A suggestion row is not focused; the field
being typed into is. What survives is debounced per element, so a word typed one
letter at a time becomes one `input` event carrying the finished text.

Focus changes get the same scepticism. One ⌘L fired three of them for the same
field, two on the window itself, so only focus landing on something typeable or
pressable is reported — and the de-duplication key is updated **only for what is
actually reported**, because letting a filtered-out window event update it let
the address bar through twice in the same millisecond.

### A gesture ends when something else happens

Coalescing buys quiet at the cost of ordering. A scroll is written down 400ms
after the wheel stops, so a page load one moment later took sequence 2 while the
scroll that preceded it took 3 — a trajectory in the wrong order. A click, a
focus change or a load now force-flushes whatever is in flight, because each of
them definitively ends it.

A gesture may not coalesce forever, either. Debouncing on quiet alone has a
hole — someone who keeps scrolling never goes quiet — and measured, six seconds
of continuous wheel movement produced **no events at all**, the whole gesture
waiting for a pause that never came. A scroll in flight for more than two
seconds is written down anyway, so a long scroll is reported in pieces rather
than as silence. Typing is capped at five, more loosely because each
notification carries the field's whole value, so a late flush still has the
complete text.

When a flush empties both buffers at once they are written down **oldest
first**, by when each gesture began. The buffers are examined in a fixed
order — scroll, then input — which has nothing to do with which happened first,
so someone who starts typing and then scrolls before the field settles would
otherwise have the scroll given the lower sequence number, contradicting these
events' own timestamps. Measured: typing at +0.34s and a scroll at +0.54s,
forced out together by a click at +0.80s, come back in that order.

**Stopping flushes what is in flight.** A demonstration that ends within the
debounce window — 0.7s of the last keystroke, 0.4s of the last wheel movement —
has its final gesture still sitting in a buffer, and that is precisely the last
thing the person did. `browser_record_stop` flushes before stopping the run
loop, on the calling thread, because the recorder thread is about to be told to
exit and may never run its timer again.

### Who did it

Every event says `user` or `agent`, because a trajectory that cannot tell the
demonstration from the replay is not a demonstration. Agent actions arrive by
two routes and need two mechanisms:

- **Synthesized input** — `browser_scroll`, `browser_back` — carries a magic
  value in `.eventSourceUserData`, and the tap recognises its own reflection
  exactly.
- **`AXPress` and value writes** post no event at all. Their only trace is the
  `AXValueChanged` or `AXLoadComplete` that follows, which looks precisely like
  a person's, so there is nothing to tag: a short window after the call is
  attributed to the agent instead.

A coalesced event records the source it **arrived** with, not the one in force
when it is flushed. Deciding at flush time gets it wrong in both directions: a
gesture begun during the agent's window is credited to the user once that window
closes, and one the user began before an agent action is credited to the agent.
For the same reason a buffer is closed off rather than extended when the author
changes — the agent scrolling through a page the user was already scrolling is
two gestures, not one distance attributed to whoever moved last.

### Waiting means waiting until they stop

Returning at the first event is the obvious implementation and the wrong one.
Measured against a scripted demonstration — navigate, click, scroll, type — it
answered after the navigation and reported one event, with the other three
arriving seconds later to nobody. A demonstration is finished when the person
stops, not when they start, so `wait_seconds` is a *budget* and the call returns
once the browser has been quiet for `settle_seconds`.

Quiet is measured by the **latest sequence number**, never by how many events
came back. A page is capped at `limit`, so once it is full its length stops
changing while events keep arriving — a count-based check reads a busy browser
as a quiet one and returns in the middle of the demonstration it was meant to
wait out. Sequence numbers are monotonic and never reused, so they cannot say
that.

### The recorder owns a thread

Both mechanisms deliver through a `CFRunLoop`, and this server's main thread is
parked in the stdio loop. So the recorder starts a thread and runs a run loop
there for as long as recording lasts.

That has a consequence worth knowing: **which application is frontmost cannot
come from an `NSWorkspace` notification**, because those are delivered on a main
run loop that is not running. The cached value would have stayed at whatever was
in front when recording began, and every click would have been discarded as
belonging to another application. It comes from the system-wide Accessibility
element instead, which answers from any thread — and is asked on every tapped
event rather than cached, because the lookup is free (measured at under a
microsecond; the Accessibility client library caches it) and a cache refreshed
on a timer leaves a window in which a click made just after switching away still
looks like the browser's.

**Frontmost is not the same as topmost at a given pixel.** A panel, a Spotlight
window or any non-activating window can sit over the browser while the browser
still owns the keyboard, and the terminal beside it is simply not covered by the
browser's window at all. So a click is hit-tested through the **system-wide**
element and the owner of whatever answers is checked against the browser.
Asking the browser's own tree — the obvious thing — answers with whatever the
browser has underneath that point, which is not what was clicked, leaving the
frontmost check as the only thing between a click anywhere on screen and a
recorded browser event. Measured with Safari frontmost for *both* clicks: one
inside its window recorded as `button "Reply…"`, one 600 points to its left over
Terminal recorded as nothing.

A hit that resolves to another application is dropped; no answer at all still
records a click with no name, because the frontmost check has already passed and
parts of a browser publish nothing.

### Notifications are advisory

The server declares the `logging` capability and pushes each recorded event as
`notifications/message` while a recording runs, so nothing is sent unbidden.
Being honest about what that buys: a notification is one-way and **does not wake
a model**. Clients differ in whether they display, log or drop one, and none
will interrupt an agent mid-turn. It is for a human watching the client's log,
and for clients that grow better handling later — `browser_events_read` with
`wait_seconds` remains the mechanism an agent should rely on.

### When to fall back to pixels

A canvas, a chart, a map or a WebGL view publishes no semantics. For those —
and only those — `macos_capture_window` plus `image_ocr` is the answer. The
split mirrors the game side: a fast semantic path, a slow visual one.

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
│   ├── BrowserAX/       # Accessibility backend (Safari, Edge) + shared model
│   │                    # plus the demonstration recorder (observer + event tap)
│   ├── BrowserCDP/      # Chrome over the DevTools protocol
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

**No `browser_` tools**: neither backend can serve. For Safari that means
Accessibility is not granted, and the grant belongs to the application that
*launches* the server — your terminal, or the MCP client — not to
`nautilus-mcp` itself and not to the browser. Add that application in System
Settings → Privacy & Security → Accessibility and restart it. Because the grant
follows the launcher, switching MCP clients means granting again, while
reinstalling the server does not.

**`browser_observe` on Chrome returns only the toolbar**: that is the AX
backend answering because no CDP endpoint was found. Chrome will not expose its
page through Accessibility at all. Start Chrome with `--remote-debugging-port`
and its own `--user-data-dir`, then restart the server; the startup log says
which backends are live.

**No `browser_record_*` tools**: they need Accessibility for both halves — the
notifications to be delivered and the event tap to be allowed to exist — so
unlike the control tools there is no CDP fallback. Same grant, same place, and
it belongs to the application that launches the server.

**No `ask_local_model`**: the on-device model is unavailable (not Apple silicon,
or Apple Intelligence off). Logged at startup; the tool is simply absent.

**Screen capture returns nothing**: grant Screen Recording to the app that
launched the server, then restart it.

## What is deliberately not here

The agent (app-server client, backend spawning, goals, skills, conversation
memory), the Windows C# frontend, speech recognition, and the voice REPL. They
live in the history of [voice-agent](https://github.com/fpt/voice-agent).
