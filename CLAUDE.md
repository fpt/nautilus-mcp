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
| `image.rs` | `ImageContent` — all that survives of the old `llm.rs`. |
| `nautilus.udl` | UniFFI interface definition. |

The FFI surface is **generic on purpose**: `tools()` + `call(name, args_json)`.
Adding an Android primitive needs no `.udl` change and no regenerated bindings.

### Swift targets (`swift/Sources/`)

| Target | Purpose |
|---|---|
| `NautilusMcp` | Executable. Argument parsing and the stdio loop — nothing else. |
| `NautilusKit` | MCP protocol (`MCPServer`), the tool protocol, and every tool implementation. Where the work is, and what the tests cover. |
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
- **No crop / OCR / image-diff** on the Android side — those need an image
  decoder in the crate. (macOS has all three.)

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
