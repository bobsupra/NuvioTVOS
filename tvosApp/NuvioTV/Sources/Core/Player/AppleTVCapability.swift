import Foundation

/// The real playback ceiling for the Apple TV model this process is running
/// on, used to keep `SmartPlaybackSelector` from offering a source the
/// hardware cannot actually decode.
struct AppleTVCapability: Equatable {
    let maxResolution: Int
    let supportsHDR: Bool
    let supportsDolbyVision: Bool
    let supportsHEVCHardwareDecode: Bool
    let supportsAV1HardwareDecode: Bool
    var supportsLiquidGlass: Bool = true

    init(
        maxResolution: Int,
        supportsHDR: Bool,
        supportsDolbyVision: Bool,
        supportsHEVCHardwareDecode: Bool,
        supportsAV1HardwareDecode: Bool,
        supportsLiquidGlass: Bool = true
    ) {
        self.maxResolution = maxResolution
        self.supportsHDR = supportsHDR
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsHEVCHardwareDecode = supportsHEVCHardwareDecode
        self.supportsAV1HardwareDecode = supportsAV1HardwareDecode
        self.supportsLiquidGlass = supportsLiquidGlass
    }

    private static let unrestricted = AppleTVCapability(
        maxResolution: 2160,
        supportsHDR: true,
        supportsDolbyVision: true,
        supportsHEVCHardwareDecode: true,
        supportsAV1HardwareDecode: false,
        supportsLiquidGlass: true
    )

    private static let table: [String: AppleTVCapability] = [
        // Apple TV HD / A1625 (2015, A8): 1080p SDR ceiling.
        "AppleTV5,3": AppleTVCapability(
            maxResolution: 1080,
            supportsHDR: false,
            supportsDolbyVision: false,
            supportsHEVCHardwareDecode: false,
            supportsAV1HardwareDecode: false,
            supportsLiquidGlass: false
        ),
        // Apple TV 4K 1st gen / A1842 (2017, A10X): 4K HDR playback, but PowerVR GT7900 GPU
        // cannot sustain real-time tvOS 26 Liquid Glass shaders at 4K without dropping frames.
        "AppleTV6,2": AppleTVCapability(
            maxResolution: 2160,
            supportsHDR: true,
            supportsDolbyVision: true,
            supportsHEVCHardwareDecode: true,
            supportsAV1HardwareDecode: false,
            supportsLiquidGlass: false
        ),
        "AppleTV11,1": unrestricted,
        "AppleTV14,1": unrestricted,
    ]

    static func capability(for identifier: String) -> AppleTVCapability {
        table[identifier] ?? unrestricted
    }

    /// Unknown hardware remains unrestricted until explicitly verified.
    static let current: AppleTVCapability = capability(for: hardwareIdentifier())

    func isPlayable(tags: StreamQualityTags) -> Bool {
        if tags.resolution > 0, tags.resolution > maxResolution { return false }
        if tags.isDolbyVision, !supportsDolbyVision { return false }
        if tags.isHDR, !supportsHDR { return false }
        return true
    }

    static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
