# nautilus-mcp

A **headless MCP server** that gives an MCP client eyes on a Mac and hands on an
Android device — and is the one server you register: the MCP servers you are
developing sit behind it, restarted whenever you rebuild them.

It runs no model of its own and drives no agent. It exposes what the machine can
do — read the screen, recognise text, speak, tap and swipe a phone — and lets
whatever is on the other end of the protocol decide what to do with them.

```
MCP client (Claude Code, …)
        │  stdio, JSON-RPC 2.0
        ▼
   nautilus-mcp  ── macOS: ScreenCaptureKit · Vision OCR · AVSpeech · Foundation Models
        │
        ├──────── Android: adb (screenshot, tap, swipe, keys)
        ├──────── your MCP servers: <server>__<tool> (stdio, HTTP, SSE, OAuth)
        └──────── your commands: `make test` as a tool
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
| `browser_observe` | read the page in Safari as roles, names and ids |

**The browser is read, never driven.** `browser_observe` is the only browser
tool, and it has no counterpart that clicks, types, scrolls or navigates. The
window it reads is the user's own — their logins, their attention, their screen —
so a synthesized click would land on a link nobody chose, and could not be taken
back. Reading costs them nothing. Anything that has to act on a browser belongs
above this server, where a person can see it coming. Safari and Edge answer;
Chrome publishes no page through Accessibility and reads as toolbar only.

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

Needs a Rust toolchain; macOS 26+ for the Mac tools (see **Linux** below
otherwise); and — for the Android tools — `adb` on PATH with USB debugging
enabled on the device.

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

> On macOS this installs two binaries: `nautilus-mcp`, the hub you register,
> and `nautilus-mcp-macos`, the Swift server it runs behind it. The latter links
> `libnautilus_core.dylib` by absolute path into this repo's
> `crates/target/release`, so keep the repo where it is.

### Options

| flag | |
|---|---|
| `--android <serial\|auto\|off>` | which device to bind (default `auto`) |
| `--voice <identifier>` | voice for `say` (or `NAUTILUS_TTS_VOICE`) |
| `--config <path>` | the config file (or `NAUTILUS_CONFIG`; default `~/.config/nautilus/config.toml`) |
| `--core <path\|off>` | the core server (default: `nautilus-mcp-macos` beside the binary, else in-process) |
| `--poll`, `--settle`, `--start-timeout` | rebuild and config polling (1s), settle time (300ms), start limit (30s) |
| `--list-tools` | print the tool names and exit |

### Permissions

macOS gates screen access. The first capture prompts for **Screen Recording**
for whichever app launched the server; grant it in
System Settings → Privacy & Security and restart that app.

### Linux

On Linux (or anywhere without the Apple frameworks) there is no Swift server;
`make install` installs the Rust hub alone, which then serves the part of the
tool set that does not need macOS in-process:

| | |
|---|---|
| `android_*` | all nine primitives, plus `android_read_text` when OCR is available |
| `image_crop`, `image_diff` | on frames from `android_observe`, with the same stale-frame refusal |
| `image_ocr` | through the `tesseract` CLI, if installed (`apt install tesseract-ocr tesseract-ocr-jpn`) |
| `nautilus_status` | always present: what is here, and why anything is missing |
| `nautilus_refresh` | look again after plugging in a device (or installing tesseract) — no session restart |
| proxying, wrappers | everything in the next section |

Screen capture, `image_regions`, `visual_*`, `browser_observe`, `say` and
`ask_local_model` are macOS-only and absent, not stubbed.

```bash
make install                  # ~/bin/nautilus-mcp, pure Rust
claude mcp add nautilus -- ~/bin/nautilus-mcp
```

## Other MCP servers, behind this one

When you develop an MCP server, your agent keeps running the build that was
current when the session started. Register nautilus-mcp once and list your
servers in its config: it restarts a server when its binary changes, picks up
config edits while it runs, and tells the client the tool list changed.

```bash
nautilus-mcp add godev -- ~/src/go-dev-mcp/output/godevmcp serve   # a local stdio server
nautilus-mcp add example https://mcp.example.com/mcp               # streamable HTTP or SSE
nautilus-mcp auth example                                          # OAuth in the browser, if needed
nautilus-mcp wrap test 'make test'                                 # a shell command as a tool
nautilus-mcp ls -v
```

Everything lives in the same `~/.config/nautilus/config.toml` as `[tts]` — see
`config.example.toml`. The config is the allowlist: nothing is launched,
contacted or run unless it is listed there.

| | |
|---|---|
| restart on rebuild | the executable and any `watch` files are checked on every call and every second; a failed build keeps its tools listed and reports its stderr |
| validation | arguments are checked against the schema of the build running *now*, and a mismatch returns the current schema |
| `nautilus_status` | every server: running or not, its tools, its last error |
| `nautilus_search_tools`, `nautilus_call_tool` | reach tools the client's own tool search has not indexed yet |
| `nautilus-mcp tools`, `call` | the same servers from a terminal: `call godev search_godoc query=mcp` |

This is [go-mcpproxy](https://github.com/fpt/go-mcpproxy), merged in. Its own
config file is not read; move servers over with `nautilus-mcp add`. Built-in
tools are `nautilus_*` rather than `mcpproxy_*`.

## Development

See **[CLAUDE.md](CLAUDE.md)** for the architecture, the invariants worth
knowing, and what is deliberately not here.

```bash
make test        # Rust + Swift (Rust only on Linux)
make gen-uniffi  # after changing crates/lib/src/nautilus.udl
```

## Lineage

nautilus-mcp began as the platform half of
[voice-agent](https://github.com/fpt/voice-agent), a macOS/Windows voice
assistant. The agent, the Windows frontend and speech recognition were removed;
the screen perception and the Android controls stayed.

## License

MIT OR Apache-2.0. See [LICENSE.txt](LICENSE.txt).
