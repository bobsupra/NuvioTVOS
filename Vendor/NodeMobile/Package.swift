// swift-tools-version: 5.9
import PackageDescription

// Node.js 24 for tvOS (nodejs-mobile, MIT), the runtime the original AIOStreams
// runs in inside Nuvio (AIOStreamsHost). Built and published by
// david325345/NuvioTVOS's .github/workflows/build-node-tvos.yml; after a new
// build, update the URL and the checksum the workflow prints.
let package = Package(
    name: "NodeMobile",
    platforms: [
        .tvOS("18.0"),
    ],
    products: [
        .library(
            name: "NodeMobile",
            targets: ["NodeMobile"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "NodeMobile",
            url: "https://github.com/david325345/NuvioTVOS/releases/download/node-tvos-v24.20.0-0/NodeMobile.xcframework.zip",
            checksum: "4aa6b3a44bd2e05d0f6fb953eab855442429ebbb5251965c5c0100bbbee8ed57"
        ),
    ]
)
