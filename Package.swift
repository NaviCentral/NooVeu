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
        .library(name: "NooVeuShell", targets: ["NooVeuShell"]),
    ],
    targets: [
        // Decoding, folder listing, caching and scheduling. No AppKit, no Metal.
        .target(name: "NooVeuCore"),
        // The Metal image canvas and the maths behind zoom and pan.
        .target(name: "NooVeuRender", dependencies: ["NooVeuCore"]),
        // The viewer window's logic with no AppKit in it: key bindings, the load/upgrade/flip state
        // machine, status text. Driven by fakes in tests.
        .target(name: "NooVeuShell", dependencies: ["NooVeuCore"]),
        // The AppKit application shell.
        .executableTarget(name: "NooVeuApp", dependencies: ["NooVeuCore", "NooVeuRender", "NooVeuShell"]),
        // Test-corpus generator and benchmark harness for the performance targets.
        .executableTarget(name: "NooVeuBench", dependencies: ["NooVeuCore", "NooVeuRender"]),
        .testTarget(name: "NooVeuCoreTests", dependencies: ["NooVeuCore"]),
        .testTarget(name: "NooVeuRenderTests", dependencies: ["NooVeuRender"]),
        .testTarget(name: "NooVeuBenchTests", dependencies: ["NooVeuBench"]),
        .testTarget(name: "NooVeuShellTests", dependencies: ["NooVeuShell"]),
    ],
    swiftLanguageModes: [.v6]
)
