import Foundation
import CoreGraphics

/// Information about a screen window
public struct WindowInfo: Sendable {
    public let windowID: UInt32
    public let title: String?
    public let appName: String?
    public let bundleId: String?
    public let frame: CGRect

    /// One-line description for situation messages
    public var summary: String {
        let app = appName ?? "?"
        let win = title ?? "untitled"
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        return "\(app) — \(win) (\(size))"
    }

    /// Structured description for find_window results.
    /// Includes window_id for use with capture_screen.
    public var findWindowDescription: String {
        let app = appName ?? "?"
        let win = title ?? "untitled"
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        return "id: \(windowID) | \"\(win)\" | app: \(app) | \(size)"
    }
}
