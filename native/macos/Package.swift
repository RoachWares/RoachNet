// swift-tools-version: 6.0
import PackageDescription

// The native runtime (RoachNetRuntime + roachnet-runtime) is Foundation-only so
// it also builds and tests on Linux CI. The AppKit/SwiftUI shell targets are
// macOS-only.
var products: [Product] = [
    .executable(name: "roachnet-runtime", targets: ["RoachNetRuntimeHost"]),
]

var targets: [Target] = [
    .target(
        name: "RoachNetRuntime",
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
        path: "Tests/RoachNetAppTests"
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
