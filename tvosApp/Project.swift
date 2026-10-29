import Foundation
import ProjectDescription

// MARK: - Submodule Validation
//
// If the repository was cloned without `--recurse-submodules`, MPVKit/Package.swift
// will be missing. Attempt automatic submodule initialization or halt with a
// clear actionable error message.
let mpvKitManifest = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("../MPVKit/Package.swift")
    .standardized

if !FileManager.default.fileExists(atPath: mpvKitManifest.path) {
    let repoRoot = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .appendingPathComponent("..")
        .standardized
    let process = Process()
    process.currentDirectoryURL = repoRoot
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["submodule", "update", "--init", "--recursive"]
    try? process.run()
    process.waitUntilExit()

    if !FileManager.default.fileExists(atPath: mpvKitManifest.path) {
        fatalError("""
        \n\n❌ [NuvioTV] Missing MPVKit submodule manifest at: \(mpvKitManifest.path)
        Please initialize git submodules by running:
            git submodule update --init --recursive
        \n
        """)
    }
}

// MARK: - Signing
//
// Tuist declares signing *settings* only. Certificate and provisioning-profile
// material never enters this repository — see Configurations/README.md.
//
// Configurations/Signing.xcconfig is tracked and always present, so it is
// referenced unconditionally. It optional-includes the untracked
// Signing.local.xcconfig, where DEVELOPMENT_TEAM lives. A fresh clone with no
// local file generates and builds unsigned, which is how releases ship
// (scripts/build-ipa.sh).

let signingXCConfig: Path = .relativeToManifest("Configurations/Signing.xcconfig")

// MARK: - Shared values

let bundleID = "com.pyksel.nuviotvos"
let marketingVersion = "3.4.8"
let projectVersion = "79"
// LibTrueHD 3.0.0 requires tvOS 18; APAC rendering itself is gated to tvOS 26+.
let tvOSDeployment = "18.0"

// MARK: - Project-level settings
//
// Carried over verbatim from the hand-maintained project.pbxproj. The warning
// flags Xcode sets by default are supplied by `defaultSettings: .recommended`
// and are not repeated here.

let projectBaseSettings: SettingsDictionary = [
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED": "YES",
    "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
    "CLANG_CXX_LIBRARY": "libc++",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu99",
    // Inert on a tvOS-only project, but the original set it project-wide and
    // without it the extension floats up to the current SDK version.
    "IPHONEOS_DEPLOYMENT_TARGET": "15.1",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["/usr/lib/swift", "$(inherited)"],
    "LIBRARY_SEARCH_PATHS": "$(inherited)",
    "SDKROOT": "appletvos",
    "TARGETED_DEVICE_FAMILY": "3",
    "TVOS_DEPLOYMENT_TARGET": .string(tvOSDeployment),
    "SWIFT_VERSION": "5.0",
    "MARKETING_VERSION": .string(marketingVersion),
    "CURRENT_PROJECT_VERSION": .string(projectVersion),
]

let debugSettings: SettingsDictionary = [
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_SYMBOLS_PRIVATE_EXTERN": "NO",
    "MTL_ENABLE_DEBUG_INFO": "YES",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    // Keep Swift's global `DEBUG` undefined, as in the hand-maintained
    // project: enabling it turns on 21 existing blocks across 7 files and
    // currently fails to build at TVCatalogRow.swift:259. The dedicated
    // watchdog condition enables only this diagnostic code in Debug.
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) NUVIO_MPV_MEMORY_WATCHDOG",
]

let releaseSettings: SettingsDictionary = [
    "COPY_PHASE_STRIP": "YES",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "VALIDATE_PRODUCT": "YES",
]

// Tuist's `.recommended` defaults inject SWIFT_ACTIVE_COMPILATION_CONDITIONS
// = DEBUG at target level, which overrides anything set project-wide. Excluding
// the key is the only way to reproduce the original project, which never set
// it. See the note on debugSettings above.
let defaultSettings: DefaultSettings = .recommended(
    excluding: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
)

func configurations(base: SettingsDictionary = [:]) -> [Configuration] {
    [
        .debug(name: "Debug", settings: base.merging(debugSettings) { _, new in new }, xcconfig: signingXCConfig),
        .release(name: "Release", settings: base.merging(releaseSettings) { _, new in new }, xcconfig: signingXCConfig),
    ]
}

// MARK: - Targets

let appTarget: Target = .target(
    name: "NuvioTV",
    destinations: [.appleTv],
    product: .app,
    productName: "NuvioTV",
    bundleId: bundleID,
    deploymentTargets: .tvOS(tvOSDeployment),
    infoPlist: .file(path: "NuvioTV/Info.plist"),
    // NuvioTV/AppDelegate.swift is deliberately NOT globbed. It carries
    // @UIApplicationMain while NuvioTVApp.swift carries @main; compiling both
    // is a duplicate-entry-point error. The pbxproj excluded it the same way.
    sources: ["NuvioTV/Sources/**/*.swift"],
    resources: [
        "NuvioTV/Images.xcassets",
        "NuvioTV/Resources/AppLanguageCatalog.json",
        "NuvioTV/Resources/AppIcon.png",
        "NuvioTV/Resources/AudioLicenses/*.txt",
        "NuvioTV/Fonts/inter_variable.ttf",
        "NuvioTV/SplashScreen.storyboard",
        "NuvioTV/Resources/SceneModels/SFace.mlpackage",
        "NuvioTV/Resources/SceneModels/YuNet.mlpackage",
        "NuvioTV/Resources/SceneModels/SFace-LICENSE.txt",
        "NuvioTV/Resources/SceneModels/YuNet-LICENSE.txt",
    ],
    entitlements: .file(path: "NuvioTV/NuvioTV.entitlements"),
    scripts: [
        // Must run after frameworks are embedded. Tuist emits post-scripts
        // after the embed phases, which satisfies the ordering the original
        // project achieved by hand-placing this phase.
        // Invoked through /bin/sh rather than by path, exactly as the original
        // project did. `.post(path:)` execs the file directly, which needs the
        // executable bit the tracked script does not carry.
        .post(
            script: "/bin/sh \"${SRCROOT}/Scripts/thin_aether_simulator_frameworks.sh\"",
            name: "Thin Aether Simulator Frameworks",
            basedOnDependencyAnalysis: false
        ),
    ],
    dependencies: [
        .target(name: "TopShelf"),
        .package(product: "AetherEngine"),
        .package(product: "AetherEngineSMB"),
        .package(product: "LibTorrent"),
        .package(product: "MPVKit"),
        .package(product: "SwiftAssRenderer"),
        .package(product: "Realtime"),
    ],
    settings: .settings(
        base: [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ENABLE_BITCODE": "NO",
            "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/../Vendor/LibTorrent"],
            "HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/../Vendor/LibTorrent"],
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "OTHER_LDFLAGS": ["$(inherited)", "-ObjC", "-lc++", "-framework", "SystemConfiguration"],
            "SWIFT_OBJC_BRIDGING_HEADER": "NuvioTV/NuvioTV-Bridging-Header.h",
            "VERSIONING_SYSTEM": "apple-generic",
        ],
        configurations: configurations(),
        defaultSettings: defaultSettings
    )
)

let topShelfTarget: Target = .target(
    name: "TopShelf",
    destinations: [.appleTv],
    // Tuist's linter rejects a generic `.appExtension` under a tvOS app; this
    // is the dedicated product type for a Top Shelf extension.
    product: .tvTopShelfExtension,
    bundleId: "\(bundleID).TopShelf",
    deploymentTargets: .tvOS(tvOSDeployment),
    infoPlist: .file(path: "TopShelf/Info.plist"),
    sources: [
        "TopShelf/**/*.swift",
        // Shared with the app target today. The Phase 2 module split moves
        // this into a framework both targets link instead of double-compiling.
        "NuvioTV/Sources/Core/TopShelf/TopShelfFeed.swift",
    ],
    entitlements: .file(path: "TopShelf/TopShelf.entitlements"),
    settings: .settings(
        base: [
            "CODE_SIGN_STYLE": "Automatic",
            "GENERATE_INFOPLIST_FILE": "NO",
            "LD_RUNPATH_SEARCH_PATHS": [
                "$(inherited)",
                "@executable_path/Frameworks",
                "@executable_path/../../Frameworks",
            ],
            "SKIP_INSTALL": "YES",
        ],
        configurations: configurations(),
        defaultSettings: defaultSettings
    )
)

let unitTestsTarget: Target = .target(
    name: "NuvioTVTests",
    destinations: [.appleTv],
    product: .unitTests,
    bundleId: "\(bundleID).tests",
    deploymentTargets: .tvOS(tvOSDeployment),
    infoPlist: .default,
    // These five files exist on disk but were never added to the pbxproj
    // Sources phase, so they have never compiled. Kept excluded to preserve
    // the current green baseline; folding them in is tracked separately.
    sources: [
        .glob(
            "NuvioTVTests/**/*.swift",
            excluding: [
                "NuvioTVTests/CatalogDecodingTests.swift",
                "NuvioTVTests/DetailsViewModelTests.swift",
                "NuvioTVTests/PerformanceTests.swift",
                "NuvioTVTests/RustSDKIntegrationTests.swift",
                "NuvioTVTests/StreamQualityTagsTests.swift",
            ]
        ),
    ],
    dependencies: [.target(name: "NuvioTV")],
    settings: .settings(
        base: [
            "CLANG_ENABLE_MODULES": "YES",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGNING_REQUIRED": "NO",
            "GENERATE_INFOPLIST_FILE": "YES",
            "LD_RUNPATH_SEARCH_PATHS": [
                "$(inherited)",
                "@executable_path/Frameworks",
                "@loader_path/Frameworks",
            ],
            // PRODUCT_NAME is intentionally left to Tuist. The original set it
            // to $(TARGET_NAME), which resolves to the same "NuvioTVTests" but
            // trips Tuist's build-time-variable lint.
            "SWIFT_EMIT_LOC_STRINGS": "NO",
        ],
        configurations: configurations(),
        defaultSettings: defaultSettings
    )
)

// UI flows have separate data/setup requirements and run through NuvioTV-UI.
let uiTestsTarget: Target = .target(
    name: "NuvioTVUITests",
    destinations: [.appleTv],
    product: .uiTests,
    bundleId: "\(bundleID).uitests",
    deploymentTargets: .tvOS(tvOSDeployment),
    infoPlist: .default,
    sources: ["NuvioTVUITests/**/*.swift"],
    dependencies: [.target(name: "NuvioTV")],
    settings: .settings(
        base: [
            "GENERATE_INFOPLIST_FILE": "YES",
            "TEST_TARGET_NAME": "NuvioTV",
            "SWIFT_EMIT_LOC_STRINGS": "NO",
        ],
        configurations: configurations(),
        defaultSettings: defaultSettings
    )
)

// MARK: - Project

let project = Project(
    name: "NuvioTV",
    organizationName: "Nuvio",
    packages: [
        .local(path: "../Vendor/AetherEngine"),
        .local(path: "../Vendor/LibTorrent"),
        .local(path: "../MPVKit"),
        .package(url: "https://github.com/mihai8804858/swift-ass-renderer.git", from: "1.3.1"),
        .package(url: "https://github.com/supabase/supabase-swift.git", .exact("2.55.4")),
    ],
    settings: .settings(
        base: projectBaseSettings,
        configurations: configurations(),
        defaultSettings: defaultSettings
    ),
    targets: [appTarget, topShelfTarget, unitTestsTarget, uiTestsTarget],
    schemes: [
        .scheme(
            name: "NuvioTV",
            shared: true,
            buildAction: .buildAction(targets: ["NuvioTV"]),
            testAction: .targets(
                ["NuvioTVTests"],
                configuration: "Debug"
            ),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
        .scheme(
            name: "NuvioTV-UI",
            shared: true,
            buildAction: .buildAction(targets: ["NuvioTV"]),
            testAction: .targets(
                ["NuvioTVUITests"],
                configuration: "Debug"
            ),
            runAction: .runAction(configuration: "Debug")
        ),
    ]
)
