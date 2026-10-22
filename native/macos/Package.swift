// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .executable(name: "roachnet-runtime", targets: ["RoachNetRuntimeHost"])
]

var targets: [Target] = [
    .target(
        name: "RoachInference",
        path: "Sources/RoachInference",
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
]

#if os(macOS)
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
        path: "Sources/RoachNetDesign",
        resources: [
            .copy("Resources/Fonts")
        ]
    ),
    .executableTarget(
        name: "RoachNetApp",
        dependencies: ["RoachNetCore", "RoachNetDesign"],
        path: "Sources/RoachNetApp",
        resources: [
            .process("Resources")
        ],
        swiftSettings: parseAsLibrary
    ),
    .executableTarget(
        name: "RoachNetSetup",
        dependencies: ["RoachNetCore", "RoachNetDesign"],
        path: "Sources/RoachNetSetup",
        swiftSettings: parseAsLibrary
    ),
]
#endif

let package = Package(
    name: "RoachNetMac",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
