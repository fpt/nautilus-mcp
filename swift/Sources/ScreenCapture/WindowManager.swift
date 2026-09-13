import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Manages window listing and screen capture using ScreenCaptureKit.
/// Must run on MainActor — ScreenCaptureKit requires CoreGraphics server init (main thread only).
@MainActor
public class WindowManager {

    /// Ensures the window server (CGS) connection is established.
    /// CLI apps don't get this automatically — AppKit apps do via NSApplication.
    private static let _ensureCGS: Void = { _ = NSApplication.shared }()

    public init() {
        _ = Self._ensureCGS
    }

    // MARK: - Window Listing

    /// Bundle id prefixes for system UI that's never a "thing the user is doing".
    private static let excludedBundlePrefixes = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.ActivityMonitor",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
    ]

    /// List on-screen windows with their metadata.
    ///
    /// With `excludeNoise: false` (default) this returns essentially everything
    /// over 50×50 — used by keyword search and the ambient title poller.
    ///
    /// With `excludeNoise: true` it returns the "what is the user actually doing"
    /// set: drops system UI (Dock, Control Center, Spotlight, …), untitled or
    /// tiny (<100×100) windows, and Chrome incognito windows (a privacy guard).
    public func listWindows(excludeNoise: Bool = false) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        let incognitoTitles = excludeNoise ? await Self.chromeIncognitoTitles() : []

        return content.windows.compactMap { window in
            if excludeNoise {
                let title = window.title ?? ""
                let bundle = window.owningApplication?.bundleIdentifier ?? ""
                let appName = window.owningApplication?.applicationName ?? ""
                if title.isEmpty { return nil }
                if window.frame.width < 100 || window.frame.height < 100 { return nil }
                // Drop windows with no owning application — desktop/system chrome
                // like the wallpaper "Backstop" layers and menu-bar strips (these
                // surface with an empty app name).
                if window.owningApplication == nil || appName.isEmpty { return nil }
                if Self.excludedBundlePrefixes.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) {
                    return nil
                }
                if bundle == "com.google.Chrome" && incognitoTitles.contains(title) { return nil }
                // Drop the terminal window hosting voice-agent itself.
                if title.lowercased().contains("voice-agent-cli") { return nil }
            } else {
                // Skip very small windows (menu bar items, etc.)
                guard window.frame.width > 50, window.frame.height > 50 else { return nil }
            }

            return WindowInfo(
                windowID: window.windowID,
                title: window.title,
                appName: window.owningApplication?.applicationName,
                bundleId: window.owningApplication?.bundleIdentifier,
                frame: window.frame
            )
        }
    }

    /// Titles of Chrome windows currently in incognito mode, via AppleScript.
    ///
    /// Runs `osascript` on a background thread (NOT the MainActor — this is called
    /// from the @MainActor capture poller) with a hard 2s deadline. On the first
    /// run macOS shows an Automation-permission prompt that blocks osascript until
    /// answered; the deadline ensures we still respond within the tool's timeout.
    /// Returns an empty set on timeout, denial, or no Chrome — i.e. fail open:
    /// nothing is filtered, the tool never hangs.
    private static func chromeIncognitoTitles() async -> Set<String> {
        await Task.detached(priority: .utility) { () -> Set<String> in
            let script = """
            tell application "System Events"
                if not (exists process "Google Chrome") then return ""
            end tell
            tell application "Google Chrome"
                set output to ""
                repeat with w in every window
                    if mode of w is "incognito" then
                        set output to output & (name of w) & linefeed
                    end if
                end repeat
                return output
            end tell
            """
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }

            // Hard deadline: don't let a permission prompt or a slow Chrome hang us.
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
                return []
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return Set(
                out.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }.value
    }

    // MARK: - Window Capture

    /// Capture a window by its ID
    public func captureWindow(windowId: UInt32) async throws -> (CGImage, WindowInfo) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
            throw CaptureError.windowNotFound("No window with ID \(windowId)")
        }

        let info = WindowInfo(
            windowID: window.windowID,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            bundleId: window.owningApplication?.bundleIdentifier,
            frame: window.frame
        )

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2 // Retina
        config.height = Int(window.frame.height) * 2

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        return (image, info)
    }

    /// Capture a window by title substring match
    public func captureByTitle(_ title: String) async throws -> (CGImage, WindowInfo) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        let titleLower = title.lowercased()
        guard let window = content.windows.first(where: {
            let winTitle = ($0.title ?? "").lowercased()
            let appName = ($0.owningApplication?.applicationName ?? "").lowercased()
            // Match against title, app name, or "app — title" combined
            return winTitle.contains(titleLower)
                || "\(appName) — \(winTitle)".contains(titleLower)
        }) else {
            throw CaptureError.windowNotFound("No window matching title '\(title)'")
        }

        let info = WindowInfo(
            windowID: window.windowID,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            bundleId: window.owningApplication?.bundleIdentifier,
            frame: window.frame
        )

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        return (image, info)
    }

    /// Capture a window by application/process name
    public func captureByProcess(_ name: String) async throws -> (CGImage, WindowInfo) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        let nameLower = name.lowercased()
        guard let window = content.windows.first(where: {
            ($0.owningApplication?.applicationName ?? "").lowercased().contains(nameLower)
        }) else {
            throw CaptureError.windowNotFound("No window for process '\(name)'")
        }

        let info = WindowInfo(
            windowID: window.windowID,
            title: window.title,
            appName: window.owningApplication?.applicationName,
            bundleId: window.owningApplication?.bundleIdentifier,
            frame: window.frame
        )

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        return (image, info)
    }

    // MARK: - Utility

    /// Crop a CGImage using normalized coordinates (0.0–1.0).
    public static func cropCGImage(
        _ image: CGImage, x: Double, y: Double, w: Double, h: Double
    ) -> CGImage? {
        let imgW = Double(image.width)
        let imgH = Double(image.height)
        let rect = CGRect(
            x: (x * imgW).rounded(),
            y: (y * imgH).rounded(),
            width: (w * imgW).rounded(),
            height: (h * imgH).rounded()
        )
        return image.cropping(to: rect)
    }

    /// Convert a CGImage to base64-encoded PNG string
    public static func cgImageToBase64(_ image: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    // MARK: - Errors

    public enum CaptureError: Error, CustomStringConvertible {
        case windowNotFound(String)
        case captureFailed(String)

        public var description: String {
            switch self {
            case .windowNotFound(let msg): return msg
            case .captureFailed(let msg): return msg
            }
        }
    }
}
