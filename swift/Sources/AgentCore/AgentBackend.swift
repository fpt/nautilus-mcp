import Foundation

/// What a frontend may ask of *any* agent, regardless of who runs the model.
///
/// Two implementations are planned (see docs/FOUNDATION_MODELS.md):
///
/// - ``AppServerBackend`` — spawns `gallium` / `codex` and drives it over
///   JSON-RPC. Inference happens in another process.
/// - a Foundation Models backend — runs `LanguageModelSession` in-process on
///   Apple silicon. Not implemented yet.
///
/// Keep this surface about *agent* concerns: running a turn, conversation
/// state, skills, goals, ambient context. Anything that only one implementation
/// needs belongs behind an optional capability instead — see
/// ``screenBridge``.
public protocol AgentBackend: AnyObject, Sendable {

    // MARK: Turns

    /// Run one conversation turn and return the reply. A turn can take minutes;
    /// implementations keep blocking work off the cooperative thread pool.
    func step(_ text: String) async throws -> AgentResponse

    /// Clear conversation history and start fresh.
    ///
    /// `async` because an implementation may have to wait for an in-flight turn:
    /// replacing a live session out from under a running response is a race, not
    /// a reset.
    func reset() async

    /// The conversation so far, formatted for display.
    func conversationHistory() async -> String

    // MARK: Configuration

    /// Set the developer/system instructions carried into the agent. `async` for
    /// the same reason as ``reset()``.
    func setSystemPrompt(_ prompt: String) async

    /// Register a skill. Whether its prompt is inlined or looked up on demand is
    /// the implementation's business.
    func addSkill(name: String, description: String, prompt: String) async

    // MARK: Ambient context

    /// Push an ambient observation (window titles, activity) the agent can read
    /// without it becoming a conversation turn.
    func pushSituationMessage(text: String, source: String, sessionId: String)

    // MARK: Goals

    func setGoal(condition: String)
    func clearGoal()
    func goalStatus() -> GoalStatus?
    func evaluateGoal() async throws -> GoalEvaluation

    // MARK: Optional capabilities

    /// How to describe this backend to the user at startup. The frontend cannot
    /// infer it from the config: a config with no `baseURL` may be a local
    /// app-server *or* the in-process on-device model, and guessing produced a
    /// banner that announced "gallium backend" while Foundation Models was
    /// running.
    var backendDescription: BackendDescription { get }

    /// Non-nil only when the backend executes its tools *out of process* and so
    /// needs the frontend to service screen-capture requests on its behalf.
    ///
    /// This is an app-server artifact: its tools live in Rust, which cannot call
    /// `WindowManager` / `OCR` / `ScreenCapture`, so it posts a request and the
    /// frontend polls and answers. A backend whose tools are Swift calls those
    /// APIs directly and returns `nil` here — no bridge, no poller, no 100 ms
    /// latency floor.
    var screenBridge: ScreenCaptureBridging? { get }
}

/// What the startup banner shows about the agent behind this session.
public struct BackendDescription: Sendable {
    /// The model, as far as the frontend can honestly state it.
    public let model: String
    /// Where inference happens.
    public let endpoint: String

    public init(model: String, endpoint: String) {
        self.model = model
        self.endpoint = endpoint
    }
}

/// The request/response bridge an out-of-process backend needs to reach macOS
/// screen APIs. Implemented by ``AppServerBackend``; the frontend drives it.
public protocol ScreenCaptureBridging: AnyObject, Sendable {
    /// Take all capture requests the backend's tools are waiting on.
    func drainCaptureRequests() -> [CaptureRequest]

    /// Answer one request. `imageBase64` is empty for text-only results.
    func submitCaptureResult(id: String, imageBase64: String, metadataJson: String)
}
