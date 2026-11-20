// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WispKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WispCore", targets: ["WispCore"]),
        .library(name: "WispMac", targets: ["WispMac"]),
        .executable(name: "wisp-bench", targets: ["wisp-bench"]),
    ],
    dependencies: [
        // On-device streaming speech-to-text (Moonshine v2; MIT; ONNX Runtime compiled in).
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", exact: "0.1.6"),
    ],
    targets: [
        // Pure logic: no AppKit, fully unit-testable.
        .target(name: "WispCore"),
        // macOS services and UI (AppKit, SwiftUI, AVFoundation, ScreenCaptureKit).
        .target(name: "WispMac",
                dependencies: ["WispCore", .product(name: "MoonshineVoice", package: "moonshine-swift")],
                resources: [.copy("Resources/Models"), .copy("Resources/Welcome")]),
        // Command-line harness for measurements (latency, pointing, STT accuracy).
        .executableTarget(name: "wisp-bench", dependencies: ["WispCore", "WispMac"]),
        .testTarget(name: "WispCoreTests", dependencies: ["WispCore"]),
        .testTarget(name: "WispMacTests", dependencies: ["WispMac"]),
    ]
)
