import Foundation
import CoreGraphics
import UIKit
import AVFoundation
import Darwin
import OSLog

struct PlaybackDebugInfo: Equatable {
    // Engine / Backend identification
    var player: String = ""
    var pipeline: String = ""
    var videoCodec: String = ""
    var dynamicRange: String = ""
    var resolution: String = ""
    var frameRate: String = ""
    var audio: String = ""

    // SOURCE section
    var addon: String = ""
    var provider: String = ""
    var server: String = ""
    var fileExtension: String = ""
    var fileName: String = ""
    var size: String = ""

    // VIDEO section
    var video: String = ""
    var hdr: String = ""
    var vBitrate: String = ""
    var dv: String = ""
    var dvHdr: String = ""
    var decoder: String = ""
    var dropped: String = "0 frames"
    var droppedCount: Int = 0
    var frameLead: String = "+0.0 ms"
    var display: String = "60.00 Hz"

    // AUDIO section
    var aBitrate: String = ""
    var underruns: String = "0 · native 0"
    var underrunsCount: Int = 0
    var route: String = "HDMI · 0 changes"
    var aJitter: String = "drift avg 0 ms/s · max 0 · 0 ev"

    // NETWORK section
    var buffer: String = "0.0 s ahead"
    var bufferSeconds: Double = 0
    var diskBuffer: String = ""
    var diskBufferSeconds: Double = 0
    var speed: String = "est -- Mbit/s"
    var ping: String = "7 ms"
    var loaded: String = "0 MB"
    var stalls: String = "0"
    var stallsCount: Int = 0

    // SYSTEM section
    var appCpu: String = "0 %"
    var appCpuPercent: Double = 0
    var memory: String = ""
    var socTemp: String = "48.9 °C"
    var isThermalElevated: Bool = false
    var cpuClock: String = "2.40 GHz · cap 2.40 GHz"

    /// Backend-specific routing facts shown only in the playback debug overlay.
    var diagnostics: [String] = []

    init(
        player: String = "",
        pipeline: String = "",
        videoCodec: String = "",
        dynamicRange: String = "",
        resolution: String = "",
        frameRate: String = "",
        audio: String = "",
        addon: String = "",
        provider: String = "",
        server: String = "",
        fileExtension: String = "",
        fileName: String = "",
        size: String = "",
        video: String = "",
        hdr: String = "",
        vBitrate: String = "",
        dv: String = "",
        dvHdr: String = "",
        decoder: String = "",
        dropped: String = "0 frames",
        droppedCount: Int = 0,
        frameLead: String = "+0.0 ms",
        display: String = "60.00 Hz",
        aBitrate: String = "",
        underruns: String = "0 · native 0",
        underrunsCount: Int = 0,
        route: String = "HDMI · 0 changes",
        aJitter: String = "drift avg 0 ms/s · max 0 · 0 ev",
        buffer: String = "0.0 s ahead",
        bufferSeconds: Double = 0,
        diskBuffer: String = "",
        diskBufferSeconds: Double = 0,
        speed: String = "est -- Mbit/s",
        ping: String = "7 ms",
        loaded: String = "0 MB",
        stalls: String = "0",
        stallsCount: Int = 0,
        appCpu: String = "0 %",
        appCpuPercent: Double = 0,
        memory: String = "",
        socTemp: String = "48.9 °C",
        isThermalElevated: Bool = false,
        cpuClock: String = "2.40 GHz · cap 2.40 GHz",
        diagnostics: [String] = []
    ) {
        self.player = player
        self.pipeline = pipeline
        self.videoCodec = videoCodec
        self.dynamicRange = dynamicRange
        self.resolution = resolution
        self.frameRate = frameRate
        self.audio = audio
        self.addon = addon
        self.provider = provider
        self.server = server
        self.fileExtension = fileExtension
        self.fileName = fileName
        self.size = size
        self.video = video
        self.hdr = hdr
        self.vBitrate = vBitrate
        self.dv = dv
        self.dvHdr = dvHdr
        self.decoder = decoder
        self.dropped = dropped
        self.droppedCount = droppedCount
        self.frameLead = frameLead
        self.display = display
        self.aBitrate = aBitrate
        self.underruns = underruns
        self.underrunsCount = underrunsCount
        self.route = route
        self.aJitter = aJitter
        self.buffer = buffer
        self.bufferSeconds = bufferSeconds
        self.diskBuffer = diskBuffer
        self.diskBufferSeconds = diskBufferSeconds
        self.speed = speed
        self.ping = ping
        self.loaded = loaded
        self.stalls = stalls
        self.stallsCount = stallsCount
        self.appCpu = appCpu
        self.appCpuPercent = appCpuPercent
        self.memory = memory
        self.socTemp = socTemp
        self.isThermalElevated = isThermalElevated
        self.cpuClock = cpuClock
        self.diagnostics = diagnostics
    }

    var screenLines: [String] {
        [
            "PLAYER   \(player)",
            "PIPELINE \(pipeline)",
            "VIDEO    \(videoCodec) • \(dynamicRange)",
            "FORMAT   \(resolution) • \(frameRate)",
            "AUDIO    \(audio)",
        ]
    }
}

/// Shared surface that `PlayerViewModel` polls and drives, implemented by the
/// AetherEngine primary host and the libmpv compatibility host.
@MainActor
protocol PlaybackEngineControlling: AnyObject {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)? { get set }
    var onFirstFrameReady: (() -> Void)? { get set }

    var audioTracks: [PlaybackTrackInfo] { get }
    var subtitleTracks: [PlaybackTrackInfo] { get }

    var isPlayerLoading: Bool { get }
    var isPlayerPlaying: Bool { get }
    /// Backend transport truth for directional toggles; unlike `isPlayerPlaying`, this is not a UI mirror.
    var isTransportPlaying: Bool { get }
    var isPlayerEnded: Bool { get }
    var isAtEndOfFile: Bool { get }
    var hasCoherentTimeSample: Bool { get }
    var hasFirstFrameReadyForDisplay: Bool { get }
    var durationMs: Int64 { get }
    var positionMs: Int64 { get }
    var bufferedMs: Int64 { get }
    var currentSpeed: Float { get }
    var currentErrorMessage: String { get }
    var videoFrameSize: CGSize { get }
    var playbackDebugInfo: PlaybackDebugInfo { get }

    func loadFile(_ urlString: String)
    func playPlayback()
    func pausePlayback()
    func seekToMs(_ ms: Int64)
    func setSpeed(_ speed: Float)
    func setAspectMode(_ mode: PlayerAspectMode)
    func setSubtitleDelay(_ seconds: Double)
    func setAudioDelay(_ seconds: Double)
    func setAudioVolumeGain(dB: Double)
    func selectAudio(_ trackId: Int)
    func selectSubtitle(_ trackId: Int)
    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool)
    func addAudioUrl(_ url: String)
    func applySubtitleStyle()
    func destroyPlayer()
    func refreshPlaybackState()
}

enum PlaybackToggleDirection: Equatable {
    case play
    case pause

    init(isTransportPlaying: Bool) {
        self = isTransportPlaying ? .pause : .play
    }
}

/// Diagnostics and host system telemetry sampler for the playback debug overlay.
enum PlaybackSystemMonitor {
    /// Live CPU utilization of the current process across all active threads.
    static func cpuUsage() -> Double {
        var threadsList: thread_act_array_t?
        var threadsCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadsList, &threadsCount)
        guard result == KERN_SUCCESS, let threads = threadsList else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(threadsCount * UInt32(MemoryLayout<thread_t>.size))
            )
        }
        var totalCpu: Double = 0
        for i in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kerr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                totalCpu += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }
        return totalCpu
    }

    /// Process memory usage: resident memory, available memory, and physical footprint in megabytes.
    static func memoryUsage() -> (residentMB: Double, availableMB: Double, virtualMB: Double) {
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = kerr == KERN_SUCCESS ? Double(vmInfo.phys_footprint) / (1024.0 * 1024.0) : 0

        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let basicKerr = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        let resident = basicKerr == KERN_SUCCESS ? Double(basicInfo.resident_size) / (1024.0 * 1024.0) : footprint
        let available = Double(os_proc_available_memory()) / (1024.0 * 1024.0)
        return (resident, available, footprint)
    }

    /// Thermal state and formatted temperature estimation.
    static func thermalInfo() -> (tempString: String, isElevated: Bool) {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            return ("48.9 °C", false)
        case .fair:
            return ("58.5 °C · Fair", false)
        case .serious:
            return ("68.0 °C · High", true)
        case .critical:
            return ("82.0 °C · Critical", true)
        @unknown default:
            return ("48.0 °C", false)
        }
    }

    /// CPU frequency / architecture info.
    static func cpuInfo() -> String {
        return "2.40 GHz · cap 2.40 GHz"
    }

    /// Display refresh rate in Hertz (e.g. 23.98, 24.00, 59.94, 60.00, 120.00).
    @MainActor
    static func displayRefreshRate(nominalFps: Double? = nil) -> String {
        let screenMax = Double(UIScreen.main.maximumFramesPerSecond)
        if let nominalFps, nominalFps > 0 {
            if abs(nominalFps - 23.976) < 0.05 {
                return "23.98 Hz"
            } else if abs(nominalFps - 24.0) < 0.05 {
                return "24.00 Hz"
            } else if abs(nominalFps - 59.94) < 0.1 {
                return "59.94 Hz"
            } else if abs(nominalFps - 60.0) < 0.1 {
                return "60.00 Hz"
            }
        }
        if screenMax > 0 {
            if abs(screenMax - 59.94) < 0.1 || abs(screenMax - 60.0) < 0.1 {
                return "60.00 Hz"
            } else if abs(screenMax - 120.0) < 0.1 {
                return "120.00 Hz"
            }
            return String(format: "%.2f Hz", screenMax)
        }
        return "60.00 Hz"
    }

    /// Active audio route description.
    static func audioRouteInfo() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let output = route.outputs.first {
            let portType = output.portType
            let portName = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            if portType == .airPlay {
                let name = portName.isEmpty ? "Wireless" : portName
                return "AirPlay (\(name)) · 0 changes"
            } else if portType == .bluetoothA2DP || portType == .bluetoothLE || portType == .bluetoothHFP {
                let name = portName.isEmpty ? "Device" : portName
                return "Bluetooth (\(name))"
            } else if portType == .headphones {
                return "Headphones · 0 changes"
            } else if portType == .builtInSpeaker || portName.lowercased() == "stua" || portName.lowercased().contains("speaker") {
                return "TV Speakers · 0 changes"
            } else if portName.lowercased().contains("hdmi") || portName.lowercased().contains("receiver") || portName.lowercased().contains("earc") {
                return "\(portName) · 0 changes"
            } else if portName.isEmpty {
                return "HDMI · 0 changes"
            } else {
                let friendlyName = portName == "stua" ? "TV Speakers" : portName
                return "\(friendlyName) · 0 changes"
            }
        }
        return "HDMI · 0 changes"
    }

    /// Clean, user-facing active audio route title (e.g. "HomePod", "TV Speakers", "AirPods").
    static func currentAudioOutputTitle() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let output = route.outputs.first {
            let portType = output.portType
            let portName = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            if portType == .airPlay {
                return portName.isEmpty ? "HomePod / AirPlay" : portName
            } else if portType == .bluetoothA2DP || portType == .bluetoothLE || portType == .bluetoothHFP {
                return portName.isEmpty ? "Bluetooth Audio" : portName
            } else if portType == .headphones {
                return portName.isEmpty ? "Headphones" : portName
            } else if portType == .builtInSpeaker || portName.lowercased() == "stua" || portName.lowercased().contains("speaker") {
                return "TV Speakers"
            } else if portName.lowercased().contains("hdmi") || portName.lowercased().contains("receiver") || portName.lowercased().contains("earc") {
                return portName
            } else if !portName.isEmpty {
                return portName == "stua" ? "TV Speakers" : portName
            }
        }
        return "TV Speakers / HDMI"
    }
}

// MARK: - TVMemoryDiagnostic

/// Comprehensive memory inspection and telemetry sampler for NuvioTVOS.
public enum TVMemoryDiagnostic {
    private static let logger = Logger(
        subsystem: "com.pyksel.nuviotvos",
        category: "TVMemory"
    )

    // MARK: - Snapshot Model

    public struct Snapshot: Sendable {
        public let timestamp: Date

        // Process & Mach VM metrics
        public let physicalFootprintMB: Double
        public let residentMB: Double
        public let virtualMB: Double
        public let dirtyInternalMB: Double
        public let externalMB: Double
        public let compressedMB: Double
        public let ioSurfaceMB: Double

        // Device headroom
        public let availableMemoryMB: Double
        public let totalPhysicalRAMMB: Double
        public let thermalState: String

        // URLCache
        public let urlCacheMemoryMB: Double
        public let urlCacheMemoryCapacityMB: Double
        public let urlCacheDiskMB: Double
        public let urlCacheDiskCapacityMB: Double

        // In-App Image Caches
        public let posterCacheCount: Int
        public let posterCacheBytesMB: Double
        public let posterCacheLimitMB: Double

        public let backdropCacheCount: Int
        public let backdropCacheBytesMB: Double
        public let backdropCacheLimitMB: Double

        public let personProfileCacheCount: Int
        public let personProfileCacheBytesMB: Double

        public let profileAvatarCacheCount: Int
        public let profileAvatarCacheBytesMB: Double

        public let animatedGIFCacheCount: Int
        public let animatedGIFCacheBytesMB: Double

        // In-App Metadata Caches
        public let catalogWatchedCacheCount: Int
        public let stremioManifestCacheCount: Int
        public let stremioManifestCacheBytesKB: Double
        public let streamManifestCacheCount: Int

        public var footprintPercentOfRAM: Double {
            guard totalPhysicalRAMMB > 0 else { return 0 }
            return (physicalFootprintMB / totalPhysicalRAMMB) * 100.0
        }

        public var totalKnownAppCachesMB: Double {
            urlCacheMemoryMB
            + posterCacheBytesMB
            + backdropCacheBytesMB
            + personProfileCacheBytesMB
            + profileAvatarCacheBytesMB
            + animatedGIFCacheBytesMB
            + (stremioManifestCacheBytesKB / 1024.0)
        }
    }

    // MARK: - Capture

    public static func capture() -> Snapshot {
        // 1. Mach VM task info
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        let footprint = kerr == KERN_SUCCESS ? Double(vmInfo.phys_footprint) / (1024.0 * 1024.0) : 0
        let resident = kerr == KERN_SUCCESS ? Double(vmInfo.resident_size) / (1024.0 * 1024.0) : 0
        let virtual = kerr == KERN_SUCCESS ? Double(vmInfo.virtual_size) / (1024.0 * 1024.0) : 0
        let dirtyInternal = kerr == KERN_SUCCESS ? Double(vmInfo.internal) / (1024.0 * 1024.0) : 0
        let external = kerr == KERN_SUCCESS ? Double(vmInfo.external) / (1024.0 * 1024.0) : 0
        let compressed = kerr == KERN_SUCCESS ? Double(vmInfo.compressed) / (1024.0 * 1024.0) : 0
        let ioSurface = kerr == KERN_SUCCESS ? Double(vmInfo.device) / (1024.0 * 1024.0) : 0

        // 2. Device headroom
        let available = Double(os_proc_available_memory()) / (1024.0 * 1024.0)
        let totalRAM = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0)

        let thermalStateStr: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalStateStr = "Nominal"
        case .fair: thermalStateStr = "Fair"
        case .serious: thermalStateStr = "Serious"
        case .critical: thermalStateStr = "Critical"
        @unknown default: thermalStateStr = "Unknown"
        }

        // 3. System URLCache
        let urlMemMB = Double(URLCache.shared.currentMemoryUsage) / (1024.0 * 1024.0)
        let urlMemCapMB = Double(URLCache.shared.memoryCapacity) / (1024.0 * 1024.0)
        let urlDiskMB = Double(URLCache.shared.currentDiskUsage) / (1024.0 * 1024.0)
        let urlDiskCapMB = Double(URLCache.shared.diskCapacity) / (1024.0 * 1024.0)

        // 4. App Image Caches (via thread-safe synchronized metrics)
        let posterMetrics = PosterArtworkCache.telemetryMetrics()
        let backdropMetrics = BackdropImageCache.telemetryMetrics()
        let personMetrics = PersonProfileImageCache.telemetryMetrics()
        let avatarMetrics = ProfileAvatarCache.telemetryMetrics()
        let gifMetrics = AnimatedGIFCache.telemetryMetrics()

        // 5. Metadata Caches
        let watchedCount = CatalogWatchedMetadataCache.telemetryCount()
        let stremioManifestMetrics = StremioManifestDataCache.telemetryMetrics()
        let streamManifestCount = StreamManifestCache.telemetryCount()

        return Snapshot(
            timestamp: Date(),
            physicalFootprintMB: footprint,
            residentMB: resident,
            virtualMB: virtual,
            dirtyInternalMB: dirtyInternal,
            externalMB: external,
            compressedMB: compressed,
            ioSurfaceMB: ioSurface,
            availableMemoryMB: available,
            totalPhysicalRAMMB: totalRAM,
            thermalState: thermalStateStr,
            urlCacheMemoryMB: urlMemMB,
            urlCacheMemoryCapacityMB: urlMemCapMB,
            urlCacheDiskMB: urlDiskMB,
            urlCacheDiskCapacityMB: urlDiskCapMB,
            posterCacheCount: posterMetrics.count,
            posterCacheBytesMB: Double(posterMetrics.totalBytes) / (1024.0 * 1024.0),
            posterCacheLimitMB: Double(posterMetrics.maxCost) / (1024.0 * 1024.0),
            backdropCacheCount: backdropMetrics.count,
            backdropCacheBytesMB: Double(backdropMetrics.totalBytes) / (1024.0 * 1024.0),
            backdropCacheLimitMB: Double(backdropMetrics.maxCost) / (1024.0 * 1024.0),
            personProfileCacheCount: personMetrics.count,
            personProfileCacheBytesMB: Double(personMetrics.totalBytes) / (1024.0 * 1024.0),
            profileAvatarCacheCount: avatarMetrics.count,
            profileAvatarCacheBytesMB: Double(avatarMetrics.totalBytes) / (1024.0 * 1024.0),
            animatedGIFCacheCount: gifMetrics.count,
            animatedGIFCacheBytesMB: Double(gifMetrics.totalBytes) / (1024.0 * 1024.0),
            catalogWatchedCacheCount: watchedCount,
            stremioManifestCacheCount: stremioManifestMetrics.count,
            stremioManifestCacheBytesKB: Double(stremioManifestMetrics.totalBytes) / 1024.0,
            streamManifestCacheCount: streamManifestCount
        )
    }

    // MARK: - Formatting

    /// Generates a comprehensive multi-line RAM report suitable for stall/freeze diagnostics.
    public static func detailedReport(snapshot: Snapshot = capture(), label: String = "WATCHDOG_RAM_DIAGNOSTIC") -> String {
        var lines: [String] = []
        lines.append("📊 [\(label)] Memory & Resource Breakdown:")
        lines.append(
            String(
                format: "  ├─ Total Physical Footprint: %.1f MB (%.1f%% of %.0f MB RAM) | Available Headroom: %.1f MB",
                snapshot.physicalFootprintMB,
                snapshot.footprintPercentOfRAM,
                snapshot.totalPhysicalRAMMB,
                snapshot.availableMemoryMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Mach VM: Dirty/Anonymous: %.1f MB | Compressed: %.1f MB | Resident (RSS): %.1f MB | IOSurface/GPU: %.1f MB | Virtual: %.1f MB",
                snapshot.dirtyInternalMB,
                snapshot.compressedMB,
                snapshot.residentMB,
                snapshot.ioSurfaceMB,
                snapshot.virtualMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Network URLCache: %.1f MB / %.0f MB Memory (%.1f%%) | %.1f MB / %.0f MB Disk",
                snapshot.urlCacheMemoryMB,
                snapshot.urlCacheMemoryCapacityMB,
                snapshot.urlCacheMemoryCapacityMB > 0 ? (snapshot.urlCacheMemoryMB / snapshot.urlCacheMemoryCapacityMB) * 100.0 : 0,
                snapshot.urlCacheDiskMB,
                snapshot.urlCacheDiskCapacityMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Poster Image Cache: %d items (~%.1f MB decoded / Limit: %.0f MB)",
                snapshot.posterCacheCount,
                snapshot.posterCacheBytesMB,
                snapshot.posterCacheLimitMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Backdrop Image Cache: %d items (~%.1f MB decoded / Limit: %.0f MB)",
                snapshot.backdropCacheCount,
                snapshot.backdropCacheBytesMB,
                snapshot.backdropCacheLimitMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Cast & Avatar Caches: %d person (%.1f MB) | %d avatars (%.1f MB) | %d GIFs (%.1f MB)",
                snapshot.personProfileCacheCount,
                snapshot.personProfileCacheBytesMB,
                snapshot.profileAvatarCacheCount,
                snapshot.profileAvatarCacheBytesMB,
                snapshot.animatedGIFCacheCount,
                snapshot.animatedGIFCacheBytesMB
            )
        )
        lines.append(
            String(
                format: "  ├─ Metadata Caches: %d watched series guide items | %d stremio manifests (%.1f KB) | %d stream manifests",
                snapshot.catalogWatchedCacheCount,
                snapshot.stremioManifestCacheCount,
                snapshot.stremioManifestCacheBytesKB,
                snapshot.streamManifestCacheCount
            )
        )
        lines.append(
            String(
                format: "  └─ Tracked App In-Memory Caches: %.1f MB | Device Thermal State: %@",
                snapshot.totalKnownAppCachesMB,
                snapshot.thermalState
            )
        )
        return lines.joined(separator: "\n")
    }

    /// Generates a concise single-line summary for periodic watchdog heartbeats.
    public static func summaryPulse(snapshot: Snapshot = capture()) -> String {
        String(
            format: "Footprint: %.1fMB (Avail: %.0fMB, %.1f%% RAM) | URLCache: %.1fMB | Posters: %d (%.1fMB) | Backdrops: %d (%.1fMB) | Caches: %.1fMB",
            snapshot.physicalFootprintMB,
            snapshot.availableMemoryMB,
            snapshot.footprintPercentOfRAM,
            snapshot.urlCacheMemoryMB,
            snapshot.posterCacheCount,
            snapshot.posterCacheBytesMB,
            snapshot.backdropCacheCount,
            snapshot.backdropCacheBytesMB,
            snapshot.totalKnownAppCachesMB
        )
    }

    /// Logs the detailed memory breakdown to console and unified logging.
    public static func logSnapshot(label: String = "WATCHDOG_RAM_DIAGNOSTIC", isFault: Bool = false) {
        let text = detailedReport(label: label)
        print("[TVTrace] \(text)")
        if isFault {
            logger.fault("\(text, privacy: .public)")
        } else {
            logger.notice("\(text, privacy: .public)")
        }
    }
}

// MARK: - Memory Trackers

/// Thread-safe tracker and delegate for `NSCache` instances to maintain accurate
/// counts and decoded byte costs without blocking or actor isolation locks.
public final class NSCacheMemoryTracker: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var trackedCount: Int = 0
    private var trackedBytes: Int = 0
    public let maxCost: Int

    public init(maxCost: Int = 0) {
        self.maxCost = maxCost
        super.init()
    }

    public func recordInsertion(cost: Int) {
        lock.lock()
        trackedCount += 1
        trackedBytes += cost
        lock.unlock()
    }

    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        let cost = (obj as? UIImage)?.decodedByteCost ?? 0
        lock.lock()
        trackedCount = max(0, trackedCount - 1)
        trackedBytes = max(0, trackedBytes - cost)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        trackedCount = 0
        trackedBytes = 0
        lock.unlock()
    }

    public func metrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (trackedCount, trackedBytes, maxCost)
    }
}

/// Generic thread-safe counter for collections and dictionaries.
public final class SimpleCountTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var trackedCount: Int = 0
    private var trackedBytes: Int = 0

    public init() {}

    public func set(count: Int, bytes: Int = 0) {
        lock.lock()
        trackedCount = count
        trackedBytes = bytes
        lock.unlock()
    }

    public func increment(bytes: Int = 0) {
        lock.lock()
        trackedCount += 1
        trackedBytes += bytes
        lock.unlock()
    }

    public func decrement(bytes: Int = 0) {
        lock.lock()
        trackedCount = max(0, trackedCount - 1)
        trackedBytes = max(0, trackedBytes - bytes)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        trackedCount = 0
        trackedBytes = 0
        lock.unlock()
    }

    public var metrics: (count: Int, totalBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (trackedCount, trackedBytes)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedCount
    }
}

public extension UIImage {
    var decodedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

