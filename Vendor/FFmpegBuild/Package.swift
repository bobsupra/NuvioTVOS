// swift-tools-version: 6.0
//
// Nuvio fork of FFmpegBuild 2.1.3: frameworks/modules namespaced as AetherLib*
// so they coexist in the same app binary with MPVKit's Libav* stack.
// Upstream: https://github.com/superuser404notfound/FFmpegBuild/tree/2.1.3
// Rebuild: re-run Vendor/namespace_ffmpegbuild.py after refreshing upstream xcframeworks.

import PackageDescription

let package = Package(
    name: "FFmpegBuild",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FFmpegBuild",
            targets: ["FFmpegBuild"]
        ),
        .library(name: "AetherLibavcodec", targets: ["AetherLibavcodec"]),
        .library(name: "AetherLibavformat", targets: ["AetherLibavformat"]),
        .library(name: "AetherLibavutil", targets: ["AetherLibavutil"]),
        .library(name: "AetherLibswresample", targets: ["AetherLibswresample"]),
        .library(name: "AetherLibswscale", targets: ["AetherLibswscale"]),
        .library(name: "AetherLibdav1d", targets: ["AetherLibdav1d"]),
        .library(name: "AetherLibavfilter", targets: ["AetherLibavfilter"]),
        .library(name: "AetherLibzimg", targets: ["AetherLibzimg"]),
        .library(name: "AetherLibzvbi", targets: ["AetherLibzvbi"]),
    ],
    targets: [
        .target(
            name: "FFmpegBuild",
            dependencies: [
                "AetherLibavcodec",
                "AetherLibavformat",
                "AetherLibavutil",
                "AetherLibswresample",
                "AetherLibswscale",
                "AetherLibavfilter",
                "AetherLibdav1d",
                "AetherLibzimg",
                "AetherLibzvbi",
            ],
            path: "Sources/FFmpegBuild",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
            ]
        ),
        .binaryTarget(name: "AetherLibavcodec", path: "Sources/AetherLibavcodec.xcframework"),
        .binaryTarget(name: "AetherLibavformat", path: "Sources/AetherLibavformat.xcframework"),
        .binaryTarget(name: "AetherLibavutil", path: "Sources/AetherLibavutil.xcframework"),
        .binaryTarget(name: "AetherLibswresample", path: "Sources/AetherLibswresample.xcframework"),
        .binaryTarget(name: "AetherLibswscale", path: "Sources/AetherLibswscale.xcframework"),
        .binaryTarget(name: "AetherLibdav1d", path: "Sources/AetherLibdav1d.xcframework"),
        .binaryTarget(name: "AetherLibavfilter", path: "Sources/AetherLibavfilter.xcframework"),
        .binaryTarget(name: "AetherLibzimg", path: "Sources/AetherLibzimg.xcframework"),
        .binaryTarget(name: "AetherLibzvbi", path: "Sources/AetherLibzvbi.xcframework"),
        .testTarget(
            name: "FFmpegBuildTests",
            dependencies: ["FFmpegBuild", "AetherLibavfilter", "AetherLibavutil"],
            path: "Tests/FFmpegBuildTests"
        ),
    ]
)
