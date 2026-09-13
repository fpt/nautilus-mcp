// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "nautilus-mcp",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        // The server. Point an MCP client at this binary.
        .executable(name: "nautilus-mcp", targets: ["NautilusMcp"]),
        // Library products so another app — an iOS one, say — can take the
        // platform-neutral pieces without the Rust cdylib or the macOS screen APIs.
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "FoundationModelsKit", targets: ["FoundationModelsKit"]),
        .library(name: "NautilusTTS", targets: ["TTS"]),
        .library(name: "NautilusUtil", targets: ["Util"]),
        // macOS only in practice: WindowManager uses AppKit and ScreenCaptureKit.
        .library(name: "ScreenCapture", targets: ["ScreenCapture"]),
        .library(name: "NautilusKit", targets: ["NautilusKit"]),
    ],
    dependencies: [],
    targets: [
        // The MCP server: protocol handling, the macOS tools, and the binding
        // to the Rust Android controls. Owns the main loop, because
        // WindowManager is @MainActor.
        // Thin shell: argument parsing and the stdio loop. Everything it drives
        // lives in NautilusKit, so the protocol and the tools stay testable.
        .executableTarget(
            name: "NautilusMcp",
            dependencies: ["NautilusKit", "BrowserCDP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MCP protocol handling plus the tool implementations.
        .target(
            name: "NautilusKit",
            dependencies: [
                "ScreenCapture", "TTS", "NautilusBridge", "FoundationModelsKit", "BrowserAX",
                "BrowserCDP",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Platform-neutral protocols and domain types. Kept because
        // FoundationModelsKit and ScreenPerception are written against them.
        .target(
            name: "AgentCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Apple's on-device model, in-process. Knows nothing about screens —
        // perception is injected.
        .target(
            name: "FoundationModelsKit",
            dependencies: ["AgentCore", "Util"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Just the logger now — the YAML agent config and the skill loader went
        // with the agent.
        .target(
            name: "Util",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TTS",
            dependencies: ["Util"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS Accessibility: semantic access to a browser window. Separate
        // from ScreenCapture because it reads structure, not pixels.
        .target(
            name: "BrowserAX",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Chrome through the DevTools protocol. Separate from BrowserAX
        // because it needs no Accessibility grant at all — it talks to the
        // renderer over a socket, which is why it still works where Chrome's
        // AXManualAccessibility no longer does.
        .target(
            name: "BrowserCDP",
            dependencies: ["BrowserAX"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ScreenCapture",
            dependencies: ["AgentCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .systemLibrary(
            name: "NautilusBridgeFFI",
            path: "Sources/NautilusBridgeFFI"
        ),
        // Generated UniFFI bindings. The Rust cdylib dependency stops here.
        .target(
            name: "NautilusBridge",
            dependencies: ["NautilusBridgeFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-L../crates/target/release",
                    "-lnautilus_core",
                ])
            ]
        ),
        .testTarget(
            name: "NautilusKitTests",
            dependencies: ["NautilusKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ScreenCaptureTests",
            dependencies: ["ScreenCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FoundationModelsKitTests",
            dependencies: ["FoundationModelsKit", "AgentCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
