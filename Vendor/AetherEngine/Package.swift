// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
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
    // Four optional components, enabled by default in Nuvio. Upstream hosts opt in with their traits.
    // A host that wants one enables its trait
    // (`.package(url:..., traits: [...])`, or the package's traits in Xcode); without it the code is not
    // compiled and the library behind it is not linked. These components may be subject to third-party
    // patent licensing; an integrator that enables one is responsible for its own licensing. Off, the
    // matching LoadOptions are accepted and change nothing: object audio keeps the channel bridge, a
    // Profile 7 source keeps the native route, and a Dolby Vision Profile 5 / 10.0 source yields no
    // scrub still or held picture. LibDovi, FFmpeg and everything else are unaffected.
    traits: [
        .trait(
            name: "TrueHDObjectAudio",
            description: "Link LibTrueHD and the object renderer, so objectAudioRendering can render TrueHD Atmos objects to APAC."
        ),
        .trait(
            name: "DTSXObjectAudio",
            description: "Compile the DTS:X decoder (FFmpeg's dca with x_heights) and the object renderer, so objectAudioRendering can render DTS:X heights to APAC."
        ),
        .trait(
            name: "DualLayerDolbyVision",
            description: "Compile the Dolby Vision Profile 7 FEL dual-layer composer, so preferDualLayerDolbyVision can take that route."
        ),
        .trait(
            name: "DolbyVisionStillReshaping",
            description: "Compile the CPU reshaping that turns a Dolby Vision Profile 5 / 10.0 frame into a still (scrub thumbnails, I-frame stills, held pictures)."
        ),
        .default(enabledTraits: [
            "TrueHDObjectAudio",
            "DTSXObjectAudio",
            "DualLayerDolbyVision",
            "DolbyVisionStillReshaping",
        ]),
    ],
    dependencies: [
        // Nuvio uses the locally namespaced FFmpeg frameworks so this package can coexist with MPVKit.
        .package(path: "../FFmpegBuild"),
        // Pure-Swift SMB2 client (MIT) that speaks the protocol over
        // NWConnection. Replaces AMSMB2/libsmb2, which EPERMs on tvOS/iOS.
        // Pinned to the 0.3.x minor: SMBClient is pre-1.0 with an actively
        // moving API, so allow patch updates but not a minor bump.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", .upToNextMinor(from: "0.3.1")),
        // libdovi (Dolby Vision RPU parser/converter). Resolved over Git so consumers
        // and Xcode Cloud build without a sibling LibDovi checkout; the prebuilt
        // xcframework needs no Rust at build time.
        // Pinned to the minor: 1.1.0 shipped a tvOS floor raise as a minor, SwiftPM
        // floated every `from: "1.0.x"` consumer onto it and then failed on the
        // floor instead of backing off, so all of 5.x stopped resolving.
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),  // 2.1.0: dolby_vision 3.4.0, header additive only (two new CMv4.0 metadata entry points, nothing removed); 2.0.0: visionOS (xros) device + simulator slices, declared tvOS floor corrected to 17.0 (was published as 1.1.0, withdrawn: a floor raise is breaking and broke every 5.x pin that floated onto it); 1.0.2: iOS slices + x86_64 (Intel Macs)
        // TrueHD decoder that also decodes the Atmos object presentation (beds, objects, OAMD) for
        // `objectAudioRendering` (#731). The Rust `truehd` crate (Apache-2.0) behind a C API, prebuilt
        // as an xcframework like LibDovi so consumers need no Rust. Pinned to the minor for the same reason.
        .package(url: "https://github.com/superuser404notfound/LibTrueHD", .upToNextMinor(from: "3.1.0")),  // 3.1.0: the shipped binary decodes exactly again, matrix interpolation included (the object renderer needs it, #731); same API 2; 3.0.0: API 2, the bed companion (the channel presentation decoded with the object presentation) and a per-handle interpolation switch; the interpolating decode an opt-in build feature, off in that binary (#731); 2.3.1: truehd_atmos_version_string() names the truehd commit actually built in (read from Cargo.lock, LibTrueHD#2), same decoder; 2.3.0: decodes about a third faster again (harletty's truehd speed work: blocks decoded in place, table-driven Huffman, vectorised prediction filters, whole-block matrices; truehdd#42 included), byte-identical output; 2.2.1: rust_eh_personality exported weak, so it coalesces with LibDovi's copy and a host with its own Objective-C and C++ stays within compact unwind's three personality routines (#752); same decoder; 2.2.0: decodes about 30% faster (the truehd crate with its block and PCM buffers sized to the samples they hold, truehdd#42, from a fork of upstream main until that is merged), byte-identical output; 2.1.0: x86_64 in the iOS simulator slice, so a generic iOS Simulator build of a host links; same decoder; 2.0.0: transferred from Silo-Server/SiloObjectAudio and renamed (product TrueHD), rebuilt from source; same decoder as SiloObjectAudio 1.0.0
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
                .product(name: "TrueHD", package: "LibTrueHD", condition: .when(traits: ["TrueHDObjectAudio"])),
            ],
            // Silent E-AC-3 Atmos that `AtmosOutputActivator` loops beside an APAC track on tvOS, and the
            // privacy manifest for the required-reason APIs the engine calls (#920): systemUptime for
            // elapsed time, volumeAvailableCapacity before spooling to disk, and stat / attributesOfItem /
            // creationDate on its own temp files and on local media the host opens.
            resources: [
                .copy("Resources/silent-atmos.mp4"),
                .copy("Resources/PrivacyInfo.xcprivacy"),
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
        // The samples in Examples/ are drop-in files rather than apps, so nothing used to
        // compile them and they could rot the way prose rots, except a reader trusts them
        // more. Compiling them as a target (never a product, so no consumer builds it)
        // makes `swift build` and CI the guard. DemoPlayerMac is its own package and
        // excluded here; it builds with `swift build --package-path Examples/DemoPlayerMac`.
        .target(
            name: "ExampleSources",
            dependencies: ["AetherEngine"],
            path: "Examples",
            exclude: ["README.md", "DemoPlayerMac"]
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
