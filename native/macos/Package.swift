// swift-tools-version: 6.0
import PackageDescription

// The native runtime (RoachNetRuntime + roachnet-runtime) is Foundation-only so
// it also builds and tests on Linux CI. The AppKit/SwiftUI shell targets are
// macOS-only.
var products: [Product] = [
    .executable(name: "roachnet-runtime", targets: ["RoachNetRuntimeHost"]),
    .executable(name: "roachnet-infer", targets: ["RoachInferenceTool"]),
    .library(name: "RoachInference", targets: ["RoachInference"]),
]

var targets: [Target] = [
    // Native LLM inference: GGUF, tokenizers, transformer, sampler; hand-written
    // Metal kernels on Apple platforms. No third-party or ML-framework dependencies.
    .target(
        name: "RoachInference",
        path: "Sources/RoachInference",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "RoachInferenceTool",
        dependencies: ["RoachInference"],
        path: "Sources/RoachInferenceTool",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "RoachInferenceTests",
        dependencies: ["RoachInference"],
        path: "Tests/RoachInferenceTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "RoachNetRuntime",
        dependencies: ["RoachInference"],
        path: "Sources/RoachNetRuntime",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "RoachNetRuntimeHost",
        dependencies: ["RoachNetRuntime"],
        path: "Sources/RoachNetRuntimeHost",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "RoachNetRuntimeTests",
        dependencies: ["RoachNetRuntime"],
        path: "Tests/RoachNetRuntimeTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

#if os(macOS)
// RoachNetApp and RoachNetSetup declare their entry point with @main inside a
// file named main.swift. Swift 6.4's SwiftPM spots the @main and compiles them
// with -parse-as-library; earlier toolchains (the macOS 15 CI runners) treat
// main.swift as top-level code and reject @main. Saying it explicitly builds
// the same on both.
let parseAsLibrary: [SwiftSetting] = [.unsafeFlags(["-parse-as-library"])]

products += [
    .executable(name: "RoachNetApp", targets: ["RoachNetApp"]),
    .executable(name: "RoachNetSetup", targets: ["RoachNetSetup"]),
]

targets += [
    .target(
        name: "RoachNetCore",
        path: "Sources/RoachNetCore"
    ),
    .target(
        name: "RoachNetDesign",
        path: "Sources/RoachNetDesign"
    ),
    .executableTarget(
        name: "RoachNetApp",
        dependencies: ["RoachNetCore", "RoachNetDesign"],
        path: "Sources/RoachNetApp",
        resources: [
            .process("Resources"),
        ],
        swiftSettings: parseAsLibrary
    ),
    .executableTarget(
        name: "RoachNetSetup",
        dependencies: ["RoachNetCore", "RoachNetDesign"],
        path: "Sources/RoachNetSetup",
        swiftSettings: parseAsLibrary
    ),
    .testTarget(
        name: "RoachNetAppTests",
        dependencies: ["RoachNetApp", "RoachNetCore", "RoachNetSetup"],
        path: "Tests/RoachNetAppTests",
        exclude: ["Fixtures"]
    ),
]
#endif

let package = Package(
    name: "RoachNetMac",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
