# nautilus-mcp

A **headless MCP server** that gives an MCP client eyes on a Mac and hands on an
Android device.

It runs no model of its own and drives no agent. It exposes what the machine can
do — read the screen, recognise text, speak, tap and swipe a phone — and lets
whatever is on the other end of the protocol decide what to do with them.

```
MCP client (Claude Code, …)
        │  stdio, JSON-RPC 2.0
        ▼
   nautilus-mcp  ── macOS: ScreenCaptureKit · Vision OCR · AVSpeech · Foundation Models
        │
        └──────── Android: adb (screenshot, tap, swipe, keys)
```

## Tools

| tool | what it does |
|---|---|
| `macos_list_windows` | list open windows with ids, titles, apps, sizes |
| `macos_capture_window` | screenshot one window, optionally cropped |
| `macos_read_text` | OCR a window (English + Japanese) — text, not an image |
| `macos_detect_objects` | Vision object detection over a window |
| `say` | speak text through the Mac's speakers |
| `ask_local_model` | ask Apple's on-device model, which can inspect the screen itself |
| `android_observe` | screenshot the device |
| `android_info` | screen size, rotation, focused app — no screenshot |
| `android_tap` / `android_swipe` / `android_long_press` | touch input |
| `android_key` / `android_text` | hardware keys and typed text |
| `android_wait` / `android_launch_app` | pace a sequence, start an app |
| `android_tap_region` | tap a region found by `image_regions` |
| `image_ocr` | read text in a frame, with boxes |
| `image_crop` | cut a region out as a new frame |
| `image_regions` | propose areas worth inspecting |
| `image_diff` | what changed between two frames |
| `visual_learn` | remember how a UI element looks |
| `visual_find` | find a learned element again, without OCR |
| `visual_list` | what has been learned |
| `android_read_text` | capture and read the screen's text in one call |
| `android_look_for` | capture and locate a learned element in one call |

**The tool list describes this machine.** A Mac without Apple Intelligence does
not advertise `ask_local_model`; with no device attached the `android_` tools are
absent entirely. A tool that is present is one that works.

### Observe once, then look closely

Captures are cached as frames. `android_observe` and `macos_capture_window`
return a `frame_id`; `image_ocr`, `image_crop`, `image_regions` and `image_diff`
work on that id, so a whole inspect-and-act loop sends the picture across the
wire only when someone needs to see it.

Every box they return is in **whole-frame** coordinates, even one found inside a
crop of a crop — so `ocr → bbox → tap` needs no conversion.

### Coordinates are normalized

Every Android coordinate is `0.0–1.0`, never pixels, so a sequence recorded on
one device still works on another and survives a rotation. Pixels passed where a
fraction belongs are rejected rather than clamped.

## Install

Needs macOS 26+, a Rust toolchain, and — for the Android tools — `adb` on PATH
with USB debugging enabled on the device.

```bash
make install          # builds and installs ~/bin/nautilus-mcp
make list-tools       # what this machine can offer
```

Then register it:

```bash
claude mcp add nautilus -- ~/bin/nautilus-mcp
```

Or in an MCP client's config file:

```json
{
  "mcpServers": {
    "nautilus": { "command": "/Users/you/bin/nautilus-mcp" }
  }
}
```

> The binary links `libnautilus_core.dylib` by absolute path into this repo's
> `crates/target/release`, so keep the repo where it is.

### Options

| flag | |
|---|---|
| `--android <serial\|auto\|off>` | which device to bind (default `auto`) |
| `--voice <identifier>` | voice for `say` (or `NAUTILUS_TTS_VOICE`) |
| `--list-tools` | print the tool names and exit |

### Permissions

macOS gates screen access. The first capture prompts for **Screen Recording**
for whichever app launched the server; grant it in
System Settings → Privacy & Security and restart that app.

## Development

See **[CLAUDE.md](CLAUDE.md)** for the architecture, the invariants worth
knowing, and what is deliberately not here.

```bash
make test        # Rust + Swift
make gen-uniffi  # after changing crates/lib/src/nautilus.udl
```

## Lineage

nautilus-mcp began as the platform half of
[voice-agent](https://github.com/fpt/voice-agent), a macOS/Windows voice
assistant. The agent, the Windows frontend and speech recognition were removed;
the screen perception and the Android controls stayed.

## License

MIT OR Apache-2.0. See [LICENSE.txt](LICENSE.txt).
