// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CaptionBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CaptionBridgeCore", targets: ["CaptionBridgeCore"]),
        .executable(name: "CaptionBridge", targets: ["CaptionBridgeApp"]),
        .executable(name: "CaptionBridgeSmokeTests", targets: ["CaptionBridgeSmokeTests"])
    ],
    targets: [
        .target(
            name: "CaptionBridgeCore",
            dependencies: []
        ),
        .executableTarget(
            name: "CaptionBridgeApp",
            dependencies: ["CaptionBridgeCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CaptionBridgeSmokeTests",
            dependencies: ["CaptionBridgeCore"]
        ),
        .testTarget(
            name: "CaptionBridgeCoreTests",
            dependencies: ["CaptionBridgeCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
