import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Whether the machine will actually let this server do its job.
///
/// # Why a tool, when the tools already disappear
///
/// A missing grant already removes the tools it gates, and the reason is logged
/// at startup — to **stderr**, which no MCP client displays and no model ever
/// reads. So from the other side of the protocol a tool that was never
/// advertised is indistinguishable from one that does not exist, and "why can I
/// not capture the screen?" has no answer available to the thing asking.
///
/// This is the one deliberate exception to *a tool that is present is a tool
/// that works*: it is present precisely so that absence can be explained, and
/// it works whether or not anything is granted.
public enum Permissions {

    public struct Status: Sendable {
        public let name: String
        public let granted: Bool
        /// Tools that cannot do their job without it.
        public let affects: [String]
        /// Whether those tools vanish from `tools/list`, or stay and fail.
        ///
        /// The two grants genuinely differ, and saying so is the point of this
        /// tool: a uniform claim would be wrong about one of them.
        public let toolsRemoved: Bool
        /// What actually happens without it.
        public let whenDenied: String
        /// The System Settings pane, as a URL that opens it.
        public let settingsURL: String

        public init(
            name: String, granted: Bool, affects: [String], toolsRemoved: Bool,
            whenDenied: String, settingsURL: String
        ) {
            self.name = name
            self.granted = granted
            self.affects = affects
            self.toolsRemoved = toolsRemoved
            self.whenDenied = whenDenied
            self.settingsURL = settingsURL
        }
    }

    // MARK: Probes

    /// Accessibility. Live: a grant given while the server runs is seen without
    /// a restart.
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Screen Recording. `CGPreflightScreenCaptureAccess` asks without
    /// prompting, which is what a status check wants — the request variant
    /// prompts once per application and is silent forever after.
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Asking

    /// Show the system's Accessibility prompt. Returns the status afterwards.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Show the system's Screen Recording prompt.
    ///
    /// macOS shows this **once per application, ever**. If it has been declined
    /// before, this returns false and displays nothing at all, which is why the
    /// reply always names the Settings pane as well.
    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    public static func openSettings(_ url: String) -> Bool {
        guard let url = URL(string: url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: Who the grant belongs to

    /// The application macOS will attribute this process to.
    ///
    /// This matters more than anything else in the reply. The grant does **not**
    /// belong to `nautilus-mcp`; it belongs to whatever launched it — a
    /// terminal, or an MCP client. Telling someone to add `nautilus-mcp` to the
    /// Accessibility list sends them looking for a binary that will never
    /// appear there, and is why switching MCP clients means granting again
    /// while reinstalling the server does not.
    ///
    /// Found by walking up the process tree to the first entry that is a real
    /// application. That is an approximation of what TCC calls the responsible
    /// process — close enough to name the right row in Settings, and the reply
    /// says it is a best guess rather than asserting it.
    public static var responsibleApplication: (name: String, bundleID: String?)? {
        var pid = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<16 {
            guard let parent = parentPID(of: pid), parent > 1 else { break }
            pid = parent
            if let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy == .regular, let name = app.localizedName
            {
                return (name, app.bundleIdentifier)
            }
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    // MARK: Reporting

    public static let accessibilitySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    public static let screenRecordingSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static func all() -> [Status] {
        [
            Status(
                name: "accessibility",
                granted: accessibilityGranted,
                affects: ["browser_observe"],
                toolsRemoved: true,
                whenDenied:
                    "Every Accessibility read fails with kAXErrorAPIDisabled (-25211), so "
                    + "browser_observe is left out of tools/list rather than advertised. It is "
                    + "the only browser tool there is, and it only reads — this server does not "
                    + "click, type in or navigate a browser, so there is nothing here a grant "
                    + "would let it do to your window. Accessibility is seen live: grant it and "
                    + "restart the server, no logout needed. Note that Chrome publishes no page "
                    + "through Accessibility even when granted, so its tabs read as toolbar "
                    + "only; Safari and Edge answer properly. The startup notes below say what "
                    + "this run found.",
                settingsURL: accessibilitySettingsURL),
            Status(
                name: "screen_recording",
                granted: screenRecordingGranted,
                affects: [
                    "macos_list_windows", "macos_capture_window", "macos_read_text",
                    "macos_detect_objects",
                ],
                toolsRemoved: false,
                whenDenied:
                    "These stay in tools/list and fail when called — unlike Accessibility, this "
                    + "grant is not checked while the server is assembling itself, so the tools "
                    + "are built either way. ScreenCaptureKit is what refuses: every one of them "
                    + "reaches the screen through SCShareableContent. The grant also needs the "
                    + "owning application restarted before it takes effect, where Accessibility "
                    + "is seen live.",
                settingsURL: screenRecordingSettingsURL),
        ]
    }
}
