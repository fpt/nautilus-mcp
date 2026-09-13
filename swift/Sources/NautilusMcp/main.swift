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
func writeLine(_ text: String) {
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

let usage = """
    nautilus-mcp — a headless MCP server for macOS perception and Android control.

    Speaks MCP over stdio; point an MCP client at this binary.

    Options:
      --android <serial|auto|off>  Which Android device to bind (default: auto).
                                   "off" leaves the android_ tools out entirely.
      --voice <identifier>         Voice for the `say` tool.
      --prototypes <dir>           Where learned UI appearances live
                                   (default ./resources, or NAUTILUS_PROTOTYPES).
      --list-tools                 Print the tool names and exit.
      --help                       Show this message.
    """

@MainActor
func runMain() async {
    var androidSpec: String? = "auto"
    var voice: String? = ProcessInfo.processInfo.environment["NAUTILUS_TTS_VOICE"]
    var listOnly = false
    var prototypeRoot = ProcessInfo.processInfo.environment["NAUTILUS_PROTOTYPES"]

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

    // From here on stdout is the protocol; --help above still used it normally.
    claimTransport()

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
        SayTool(speech: TextToSpeech(config: .init(voice: voice))),
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

    // Browser control through Accessibility. Absent entirely without the
    // permission, with the reason on stderr — the same rule as everything else:
    // a tool that is listed is a tool that works.
    let browserTools = makeBrowserTools()
    tools.append(contentsOf: browserTools.map { Optional($0) })
    log(
        browserTools.isEmpty
            ? "no browser tools: Accessibility permission not granted — grant it to the app that "
                + "launches this server in System Settings > Privacy & Security > Accessibility"
            : "browser tools available (\(browserTools.count))")

    // Offered only where it exists. On a Mac without Apple Intelligence,
    // `make()` answers nil and ask_local_model simply is not in the list.
    let localModel = LocalModelTool.make()
    tools.append(localModel)
    log(
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
            log("bound Android device, \(androidTools.count) tool(s)")
        } catch {
            log("no Android tools: \(error.localizedDescription)")
        }
    }

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
