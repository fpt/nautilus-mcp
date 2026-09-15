import Foundation
import NautilusKit
import ScreenCapture
import TTS

// Top-level code lives in main.swift, so the entry point is the statement
// below. `@main` and top-level code cannot coexist in one target.
await runMain()

/// The real stdout, reserved for the MCP stream.
///
/// **stdout is the transport.** Any other write there corrupts the protocol —
/// and that is not hypothetical: the TTS logger printed its chosen voice at
/// startup and put a non-JSON line in the middle of the stream. Rather than
/// audit every present and future `print` in every dependency,
/// [`claimTransport`] takes a private duplicate of fd 1 and then points fd 1 at
/// stderr, so stray output is harmless by construction.
nonisolated(unsafe) var transport = FileHandle.standardOutput

func claimTransport() {
    let duplicated = dup(STDOUT_FILENO)
    guard duplicated >= 0 else { return }
    dup2(STDERR_FILENO, STDOUT_FILENO)
    transport = FileHandle(fileDescriptor: duplicated, closeOnDealloc: false)
}

/// Write one line to the MCP stream, unbuffered.
///
/// Locked. Nothing writes here but the main loop now that the recorder is gone,
/// but two writers interleaving mid-line would corrupt the protocol just as
/// surely as a stray `print`, and the lock is free when uncontended.
let transportLock = NSLock()
func writeLine(_ text: String) {
    transportLock.lock()
    defer { transportLock.unlock() }
    transport.write(Data((text + "\n").utf8))
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("nautilus-mcp: \(text)\n".utf8))
}

/// Read a line of stdin without blocking the MainActor.
///
/// Reading is a blocking syscall; doing it directly on the MainActor would pin
/// the thread the screen-capture tools need.
func readLineOffMainActor() async -> String? {
    await Task.detached { readLine(strippingNewline: true) }.value
}

/// Computed, not stored: top-level code runs `runMain()` as its first
/// statement, which is *before* a stored global declared further down this file
/// gets initialized — so `--help` printed one empty line. A computed property
/// has no initialization order to get wrong.
var usage: String { """
    nautilus-mcp — a headless MCP server for macOS perception and Android control.

    Speaks MCP over stdio; point an MCP client at this binary.

    Options:
      --android <serial|auto|off>  Which Android device to bind (default: auto).
                                   "off" leaves the android_ tools out entirely.
      --config <path>              Configuration file (TOML). Default:
                                   $NAUTILUS_CONFIG, else
                                   ~/.config/nautilus/config.toml if it exists.
      --voice <identifier>         Default voice for the `say` tool; overrides
                                   the config file. A voice per language is set
                                   in the config as [tts.en], [tts.ja], ...
      --prototypes <dir>           Where learned UI appearances live
                                   (default ./resources, or NAUTILUS_PROTOTYPES).
      --list-tools                 Print the tool names and exit.
      --help                       Show this message.
    """
}

@MainActor
func runMain() async {
    var androidSpec: String? = "auto"
    var voice: String? = ProcessInfo.processInfo.environment["NAUTILUS_TTS_VOICE"]
    var listOnly = false
    var prototypeRoot = ProcessInfo.processInfo.environment["NAUTILUS_PROTOTYPES"]
    var configPath: String?

    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--help", "-h":
            print(usage)
            return
        case "--list-tools":
            listOnly = true
        case "--android":
            androidSpec = args.isEmpty ? nil : args.removeFirst()
        case "--config":
            configPath = args.isEmpty ? nil : args.removeFirst()
        case "--voice":
            voice = args.isEmpty ? nil : args.removeFirst()
        case "--prototypes":
            prototypeRoot = args.isEmpty ? nil : args.removeFirst()
        default:
            log("unknown option \(arg)")
            print(usage)
            exit(2)
        }
    }

    // Before stdout is claimed, so a bad --config can still be reported plainly
    // and the process can refuse to start. A server that silently ignores the
    // configuration it was pointed at is worse than one that will not run.
    let config: NautilusConfig
    do {
        config = try NautilusConfig.load(explicitPath: configPath, voiceOverride: voice)
    } catch {
        log(MCPServer.explain(error))
        exit(2)
    }

    // From here on stdout is the protocol; --help above still used it normally.
    claimTransport()

    // Startup decisions are logged to stderr, which no MCP client shows and no
    // model can read — so they are kept as well, and macos_permissions hands
    // them back when someone asks why a tool is missing.
    var startupNotes: [String] = []
    func note(_ text: String) {
        startupNotes.append(text)
        log(text)
    }

    note(config.summary)

    // macOS tools. WindowManager is @MainActor, which is why the whole server
    // loop lives here.
    let manager = WindowManager()
    // Shared by every capture and every image operation: observe once, then
    // crop/OCR/diff without pushing the picture back across the protocol.
    let frames = FrameStore()
    // Learned UI appearances. Defaults to ./resources so a checkout carries its
    // own prototypes; the directory is created on the first visual_learn.
    let prototypes = PrototypeStore(
        root: URL(fileURLWithPath: prototypeRoot ?? "resources", isDirectory: true))
    // `nil` entries are capabilities this Mac lacks; the server drops them so
    // the tool list describes what actually works here.
    var tools: [MCPTool?] = [
        ListWindowsTool(manager: manager),
        CaptureWindowTool(manager: manager, store: frames),
        ReadTextTool(manager: manager),
        DetectObjectsTool(manager: manager),
        SayTool(speech: TextToSpeech(config: config.tts)),
        // Source-agnostic: these work on a frame from either capture tool.
        ImageOCRTool(store: frames),
        ImageCropTool(store: frames),
        ImageRegionsTool(store: frames),
        ImageDiffTool(store: frames),
        ImageLoadTool(store: frames),
        // Visual recognition: OCR discovers what a thing is once, these find it
        // again afterwards without depending on font or language.
        VisualLearnTool(frames: frames, store: prototypes),
        VisualFindTool(frames: frames, store: prototypes),
        VisualListTool(store: prototypes),
    ]

    // Reading a browser page, through Accessibility. Read-only on purpose: the
    // window belongs to the user, so nothing here clicks, types or navigates.
    // Absent entirely without the grant, with the reason on stderr — the same
    // rule as everything else: a tool that is listed is a tool that works.
    let browser = makeBrowserTools()
    tools.append(contentsOf: browser.tools.map { Optional($0) })
    note(browser.summary)

    // Offered only where it exists. On a Mac without Apple Intelligence,
    // `make()` answers nil and ask_local_model simply is not in the list.
    let localModel = LocalModelTool.make()
    tools.append(localModel)
    note(
        localModel == nil
            ? "no ask_local_model: the on-device model is unavailable on this Mac"
            : "on-device model available")

    // Android is optional: a Mac with nothing plugged in is a perfectly good
    // server for the macos_ tools, so a missing device is a logged warning, not
    // a failed start.
    if let androidSpec, androidSpec != "off" {
        let requested = androidSpec == "auto" ? nil : androidSpec
        do {
            let androidTools = try makeAndroidTools(serial: requested, store: frames)
            tools.append(contentsOf: androidTools)
            // Perception that captures for you, so "what is on screen" can never
            // be answered from a frame taken before the last action.
            if let observe = androidTools.first(where: { $0.name == "android_observe" }) {
                tools.append(AndroidReadTextTool(observe: observe, frames: frames))
                tools.append(
                    AndroidLookForTool(observe: observe, frames: frames, prototypes: prototypes))
            }
            note("bound Android device, \(androidTools.count) tool(s)")
        } catch {
            note("no Android tools: \(error.localizedDescription)")
        }
    }

    // Always present, and the one deliberate exception to "a tool that is
    // present is a tool that works": everything else removes itself when it
    // cannot work, and this is what makes that absence answerable from the far
    // side of the protocol, where stderr is not readable.
    tools.append(PermissionsTool(startupNotes: startupNotes))

    let server = MCPServer(name: "nautilus-mcp", version: "0.1.0", optionalTools: tools)

    if listOnly {
        for name in server.toolNames { writeLine(name) }
        return
    }

    log("ready on stdio with \(server.toolNames.count) tool(s)")
    while let line = await readLineOffMainActor() {
        if let response = await server.handle(line: line) {
            writeLine(response)
        }
    }
    log("stdin closed, exiting")
}
