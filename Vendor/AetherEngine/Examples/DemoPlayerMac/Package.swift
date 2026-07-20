// swift-tools-version: 6.0
//
// DemoPlayerMac, standalone macOS demonstrator for AetherEngine.
// Builds against the AetherEngine package via a local path so the
// demonstrator stays in lock-step with the engine source it ships
// alongside. `swift run` from this directory launches the window;
// see README.md for the .dmg packaging path.

import PackageDescription

let package = Package(
    name: "DemoPlayerMac",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "DemoPlayerMac",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
            ]
        ),
    ]
)
