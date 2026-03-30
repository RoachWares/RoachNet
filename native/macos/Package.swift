// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoachNetMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "RoachNetApp", targets: ["RoachNetApp"]),
        .executable(name: "RoachNetSetup", targets: ["RoachNetSetup"]),
    ],
    targets: [
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
    ]
)
