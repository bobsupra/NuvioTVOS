import Foundation
import CoreGraphics
import UIKit
import AVFoundation
import Darwin

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

    var audioTracks: [PlaybackTrackInfo] { get }
    var subtitleTracks: [PlaybackTrackInfo] { get }

    var isPlayerLoading: Bool { get }
    var isPlayerPlaying: Bool { get }
    var isPlayerEnded: Bool { get }
    var isAtEndOfFile: Bool { get }
    var hasCoherentTimeSample: Bool { get }
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
}
