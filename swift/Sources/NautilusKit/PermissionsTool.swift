import Foundation

/// `macos_permissions` — what this machine will let the server do, and why any
/// tool is missing.
///
/// See `Permissions` for why this exists at all when the gated tools already
/// remove themselves: the reason they did goes to stderr, which nothing on the
/// other side of the protocol can read.
@MainActor
public final class PermissionsTool: MCPTool {
    /// What was decided at startup — which browser backends came up, whether a
    /// device was found, why the on-device model is absent. Captured as the
    /// server assembled itself, so this tool answers with the real reasons
    /// rather than re-deriving guesses.
    private let startupNotes: [String]

    public init(startupNotes: [String]) { self.startupNotes = startupNotes }

    public nonisolated var name: String { "macos_permissions" }
    public nonisolated var description: String {
        "Check whether macOS has granted this server Accessibility and Screen Recording, and "
            + "find out why any tool is missing or failing. Use it when a tool you expected is "
            + "not in the list, when screen capture comes back empty, or when a browser tool "
            + "fails with a permission error. The two grants behave differently and the reply "
            + "says which applies: without Accessibility the tools that need it are left out of "
            + "the list entirely, while without Screen Recording the macos_ capture tools are "
            + "still listed and fail when called. The reply names the application the grant "
            + "to, which is the one that LAUNCHED this server (your terminal or MCP client), "
            + "never nautilus-mcp itself. Optionally shows the system prompt or opens the right "
            + "Settings pane."
    }
    public nonisolated var inputSchema: JSONValue {
        .objectSchema(properties: [
            "request": .property(
                "string",
                "Show the system permission prompt for \"accessibility\" or \"screen_recording\". "
                    + "Visible to the user, so only do this when they have asked for it. macOS "
                    + "shows the Screen Recording prompt once per application ever; if it was "
                    + "declined before, nothing appears and the Settings pane is the only route."),
            "open_settings": .property(
                "string",
                "Open System Settings at the pane for \"accessibility\" or \"screen_recording\". "
                    + "Brings Settings to the front, so ask first."),
        ])
    }

    public func call(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        var actions: [String] = []

        if let wanted = arguments.optionalString("request") {
            switch wanted {
            case "accessibility":
                Permissions.requestAccessibility()
                actions.append(
                    "Showed the Accessibility prompt. It takes effect without a restart once "
                        + "granted.")
            case "screen_recording":
                let granted = Permissions.requestScreenRecording()
                actions.append(
                    granted
                        ? "Screen Recording is granted."
                        : "Asked for Screen Recording. If no prompt appeared, this application "
                            + "has been asked before and macOS will not ask again — use "
                            + "open_settings. Either way this grant needs a restart to take "
                            + "effect.")
            default:
                throw ToolFailure(
                    "request wants \"accessibility\" or \"screen_recording\", got \"\(wanted)\"")
            }
        }

        if let wanted = arguments.optionalString("open_settings") {
            let url: String
            switch wanted {
            case "accessibility": url = Permissions.accessibilitySettingsURL
            case "screen_recording": url = Permissions.screenRecordingSettingsURL
            default:
                throw ToolFailure(
                    "open_settings wants \"accessibility\" or \"screen_recording\", got "
                        + "\"\(wanted)\"")
            }
            actions.append(
                Permissions.openSettings(url)
                    ? "Opened System Settings at the \(wanted) pane."
                    : "Could not open System Settings.")
        }

        let payload = Self.describe(
            statuses: Permissions.all(),
            responsible: Permissions.responsibleApplication,
            startupNotes: startupNotes,
            actions: actions)

        return MCPToolResult(text: try JSONValue.object(payload).serialized())
    }

    /// Render the reply.
    ///
    /// Separated from the probes so the **denied** branch can be tested. It is
    /// the branch that matters — the granted one is what every developer
    /// machine already shows — and there is no way to exercise it by running
    /// the server on a Mac where the grant exists, short of revoking it.
    nonisolated static func describe(
        statuses: [Permissions.Status],
        responsible: (name: String, bundleID: String?)?,
        startupNotes: [String],
        actions: [String]
    ) -> [String: JSONValue] {
        let grantee = responsible?.name ?? "the application that launched this server"

        var payload: [String: JSONValue] = [
            "permissions": .object(
                Dictionary(
                    uniqueKeysWithValues: statuses.map { status in
                        var entry: [String: JSONValue] = [
                            "granted": .bool(status.granted),
                            "affects": .array(status.affects.map { .string($0) }),
                        ]
                        if !status.granted {
                            // The two grants behave differently and the report
                            // says so per permission. A blanket "the tools are
                            // absent" was wrong about screen recording, whose
                            // tools stay listed and fail when called.
                            entry["effect"] = .string(
                                status.toolsRemoved
                                    ? "tools_removed_from_list" : "tools_listed_but_failing")
                            entry["what_happens"] = .string(status.whenDenied)
                            entry["how_to_grant"] = .string(
                                "System Settings → Privacy & Security → "
                                    + (status.name == "accessibility"
                                        ? "Accessibility" : "Screen Recording")
                                    + ", add \(grantee), then restart it.")
                            entry["settings_url"] = .string(status.settingsURL)
                        }
                        return (status.name, JSONValue.object(entry))
                    })),
            "grant_belongs_to": .object([
                "application": .string(grantee),
                "bundle_id": responsible?.bundleID.map { JSONValue.string($0) } ?? .null,
                "why": .string(
                    "macOS attributes the grant to the application that launched this server, not "
                        + "to nautilus-mcp and not to the browser. So switching MCP clients means "
                        + "granting again, while reinstalling the server does not. This is read "
                        + "by walking up the process tree and is a best guess; if it names "
                        + "something unexpected, grant to whatever you actually started."),
            ]),
        ]

        if !startupNotes.isEmpty {
            payload["startup"] = .array(startupNotes.map { .string($0) })
        }
        if !actions.isEmpty { payload["actions"] = .array(actions.map { .string($0) }) }

        let missing = statuses.filter { !$0.granted }
        if missing.isEmpty {
            payload["summary"] = .string(
                "Accessibility and Screen Recording are both granted.")
        } else {
            // Named separately, because what a denial does is not the same for
            // both: one removes its tools, the other leaves them listed.
            let removed = missing.filter(\.toolsRemoved).map(\.name)
            let listed = missing.filter { !$0.toolsRemoved }.map(\.name)
            var parts: [String] = []
            if !removed.isEmpty {
                parts.append(
                    "\(removed.joined(separator: ", ")) not granted, so the tools needing it are "
                        + "absent from tools/list")
            }
            if !listed.isEmpty {
                parts.append(
                    "\(listed.joined(separator: ", ")) not granted; those tools are still listed "
                        + "and will fail when called")
            }
            payload["summary"] = .string(parts.joined(separator: ". ") + ".")
        }
        return payload
    }
}
