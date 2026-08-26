// swift-tools-version: 6.0

import PackageDescription

// AE#377. Its own package rather than a target in the engine's, for one reason: the engine's
// package scheme carries aetherctl, which uses Foundation.Process and therefore cannot build for
// tvOS at all. The device that has the failure could not build the harness meant to measure it.
//
// It depends on nothing, deliberately. The question is a property of URLSession, so routing it
// through the reader under suspicion would answer a different one.
let package = Package(
    name: "TransportProbe",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    targets: [
        .testTarget(
            name: "TransportProbe",
            path: "Tests/TransportProbe"
        ),
    ]
)
