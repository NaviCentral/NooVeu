// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NooVeu",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NooVeu", targets: ["NooVeuApp"]),
        .executable(name: "nooveu-bench", targets: ["NooVeuBench"]),
        .library(name: "NooVeuCore", targets: ["NooVeuCore"]),
        .library(name: "NooVeuRender", targets: ["NooVeuRender"]),
    ],
    targets: [
        // Decoding, folder listing, caching and scheduling. No AppKit, no Metal.
        .target(name: "NooVeuCore"),
        // The Metal image canvas and the maths behind zoom and pan.
        .target(name: "NooVeuRender", dependencies: ["NooVeuCore"]),
        // The AppKit application shell.
        .executableTarget(name: "NooVeuApp", dependencies: ["NooVeuCore", "NooVeuRender"]),
        // Test-corpus generator and benchmark harness for the performance targets.
        .executableTarget(name: "NooVeuBench", dependencies: ["NooVeuCore", "NooVeuRender"]),
        .testTarget(name: "NooVeuCoreTests", dependencies: ["NooVeuCore"]),
        .testTarget(name: "NooVeuRenderTests", dependencies: ["NooVeuRender"]),
    ],
    swiftLanguageModes: [.v6]
)
