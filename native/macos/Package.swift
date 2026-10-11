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
        ]
    ),
    .executableTarget(
        name: "RoachNetSetup",
        dependencies: ["RoachNetCore", "RoachNetDesign"],
        path: "Sources/RoachNetSetup"
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
