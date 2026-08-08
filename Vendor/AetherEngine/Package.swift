// swift-tools-version: 6.0
// Nuvio pin of AetherEngine 6.7.0 — imports AetherLib* FFmpeg modules (namespaced for MPVKit coexistence).

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v16),
        .tvOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AetherEngine",
            type: .static,
            targets: ["AetherEngine"]
        ),
        .library(
            name: "AetherEngineSMB",
            targets: ["AetherEngineSMB"]
        ),
        // aetherctl is intentionally not exposed as a product. The target
        // uses Foundation.Process, which is unavailable on tvOS/iOS, so
        // exposing it would force SPM consumers to compile it on those
        // platforms. The target is preserved below so `swift build` on
        // macOS still produces the CLI for upstream development.
    ],
    dependencies: [
        // Minimal FFmpeg build (avcodec, avformat, avutil, swresample only).
        // No network stack, we use custom AVIO + URLSession for HTTP streams.
        // Nuvio: local namespaced FFmpegBuild (AetherLib*) for MPVKit coexistence.
        .package(path: "../FFmpegBuild"),
        // Pure-Swift SMB2 client (MIT) that speaks the protocol over
        // NWConnection. Replaces AMSMB2/libsmb2, which EPERMs on tvOS/iOS.
        // Pinned to the 0.3.x minor: SMBClient is pre-1.0 with an actively
        // moving API, so allow patch updates but not a minor bump.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        // libdovi (Dolby Vision RPU parser/converter). Resolved over Git like
        // FFmpegBuild so consumers (and Xcode Cloud) build without a sibling
        // LibDovi checkout; the prebuilt xcframework needs no Rust at build time.
        // Pinned to the minor for the same reason as FFmpegBuild above, with a
        // worked example: 1.1.0 shipped a tvOS floor raise as a minor, SwiftPM
        // floated every `from: "1.0.x"` consumer onto it and then failed on the
        // floor instead of backing off, so all of 5.x stopped resolving.
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.0.0")),  // 2.0.0: visionOS (xros) device + simulator slices, declared tvOS floor corrected to 17.0 (was published as 1.1.0, withdrawn: a floor raise is breaking and broke every 5.x pin that floated onto it); 1.0.2: iOS slices + x86_64 (Intel Macs)
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "FFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "AetherEngineSMB",
            dependencies: [
                "AetherEngine",
                .product(name: "SMBClient", package: "SMBClient"),
            ],
            path: "Sources/AetherEngineSMB"
        ),
        .executableTarget(
            name: "aetherctl",
            dependencies: ["AetherEngine", "AetherEngineSMB"],
            path: "Sources/aetherctl"
        ),
        .testTarget(
            name: "AetherEngineTests",
            dependencies: ["AetherEngine"],
            path: "Tests/AetherEngineTests"
        ),
        .testTarget(
            name: "AetherEngineSMBTests",
            dependencies: ["AetherEngineSMB"],
            path: "Tests/AetherEngineSMBTests"
        ),
    ]
)
