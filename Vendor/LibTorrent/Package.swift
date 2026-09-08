// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibTorrent",
    platforms: [
        .tvOS(.v15),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "LibTorrent",
            targets: ["LibTorrentEngine"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "LibTorrentEngine",
            path: "LibTorrentEngine.xcframework"
        ),
    ]
)
