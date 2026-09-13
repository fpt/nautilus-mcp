import Foundation

/// Domain types for an agent turn, defined natively rather than borrowed from
/// the UniFFI bindings.
///
/// They used to come from `AgentBridge`, which meant anything touching an
/// `AgentResponse` linked the Rust cdylib — including the Foundation Models
/// backend, which needs nothing from Rust at all. That made a pure on-device
/// build (iOS) impossible. `AppServerBackend` now maps the generated types to
/// these at its own boundary, which is where that translation belongs.

/// The result of one agent turn.
public struct AgentResponse: Sendable {
    public let content: String
    public let role: String
    public let isFinal: Bool
    public let keywords: [String]?
    public let reasoning: String?
    public let inputTokens: UInt64
    public let outputTokens: UInt64
    public let totalTokens: UInt64
    /// Share of the model's context window in use, 0-100.
    public let contextPercent: Float
    /// Self-paced cadence hint, set when the model calls `suggest_next_check`.
    public let suggestedNextCheckSeconds: UInt32?

    public init(
        content: String,
        role: String = "assistant",
        isFinal: Bool = true,
        keywords: [String]? = nil,
        reasoning: String? = nil,
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        totalTokens: UInt64 = 0,
        contextPercent: Float = 0,
        suggestedNextCheckSeconds: UInt32? = nil
    ) {
        self.content = content
        self.role = role
        self.isFinal = isFinal
        self.keywords = keywords
        self.reasoning = reasoning
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.contextPercent = contextPercent
        self.suggestedNextCheckSeconds = suggestedNextCheckSeconds
    }
}

/// State of the active goal, for the `/goal` status view.
public struct GoalStatus: Sendable {
    public let condition: String
    public let elapsedSeconds: UInt64
    public let turnsEvaluated: UInt32
    public let lastReason: String?

    public init(
        condition: String, elapsedSeconds: UInt64, turnsEvaluated: UInt32, lastReason: String?
    ) {
        self.condition = condition
        self.elapsedSeconds = elapsedSeconds
        self.turnsEvaluated = turnsEvaluated
        self.lastReason = lastReason
    }
}

/// The verdict of evaluating a goal against the conversation.
public struct GoalEvaluation: Sendable {
    public let met: Bool
    public let reason: String

    public init(met: Bool, reason: String) {
        self.met = met
        self.reason = reason
    }
}

/// A pending screen-capture request from an out-of-process backend.
///
/// Only backends whose tools run in another process raise these; an in-process
/// one calls the platform APIs directly. See `AgentBackend.screenBridge`.
public struct CaptureRequest: Sendable {
    public let id: String
    public let windowId: UInt32?
    public let cropX: Double?
    public let cropY: Double?
    public let cropW: Double?
    public let cropH: Double?
    public let detect: Bool?
    public let applyOcr: Bool?
    /// Present for find_window / list_windows; empty means "list everything".
    public let searchKeywords: String?

    public init(
        id: String,
        windowId: UInt32? = nil,
        cropX: Double? = nil,
        cropY: Double? = nil,
        cropW: Double? = nil,
        cropH: Double? = nil,
        detect: Bool? = nil,
        applyOcr: Bool? = nil,
        searchKeywords: String? = nil
    ) {
        self.id = id
        self.windowId = windowId
        self.cropX = cropX
        self.cropY = cropY
        self.cropW = cropW
        self.cropH = cropH
        self.detect = detect
        self.applyOcr = applyOcr
        self.searchKeywords = searchKeywords
    }
}
