import XCTest
import AudioToolbox
import AVFoundation
import AetherLibavutil
@testable import AetherEngine

/// #401: `AudioDecoder` resamples to `av_channel_layout_default(channels)` and then stamps the
/// format description with a layout of its own. Those are two descriptions of one buffer, and
/// they have to agree channel for channel, or the renderer places the audio somewhere the
/// decoder never put it. They agreed only for 5.0 and 5.1; on 7.1 every channel moved and the
/// LFE landed hard left at full gain.
final class ChannelLayoutOrderTests: XCTestCase {

    // MARK: - What each library says, read from the library itself

    /// The order the resampler writes, read back from the production call that sets it.
    private func resamplerOrder(_ count: Int32) -> [String] {
        var layout = AVChannelLayout()
        makeResamplerOutputLayout(count, into: &layout)
        defer { av_channel_layout_uninit(&layout) }
        return (0..<count).map { index in
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            var name = [CChar](repeating: 0, count: 64)
            _ = av_channel_name(&name, 64, channel)
            return String(cString: name)
        }
    }

    /// CoreAudio's own expansion of a layout, so the comparison is against Apple's data rather
    /// than against a second table of ours.
    private func coreAudioOrder(_ labels: [AudioChannelLabel]) -> [String] {
        labels.map { Self.name(for: $0) }
    }

    private static func name(for label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: return "FL"
        case kAudioChannelLabel_Right: return "FR"
        case kAudioChannelLabel_Center: return "FC"
        case kAudioChannelLabel_LFEScreen: return "LFE"
        case kAudioChannelLabel_LeftSurround: return "BL"
        case kAudioChannelLabel_RightSurround: return "BR"
        case kAudioChannelLabel_LeftCenter: return "FLC"
        case kAudioChannelLabel_RightCenter: return "FRC"
        case kAudioChannelLabel_CenterSurround: return "BC"
        // CoreAudio names the extra 7.1 surround pair "rear" where FFmpeg names it "side".
        // Measured through a real downmix: both place identically, so the pair is compared by
        // position rather than by which of the two names each library prefers.
        case kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft:
            return "SL"
        case kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight:
            return "SR"
        case kAudioChannelLabel_Mono: return "MONO"
        default: return "label\(label)"
        }
    }

    private func expandTag(_ tag: AudioChannelLayoutTag) -> [AudioChannelLabel] {
        var t = tag
        var size: UInt32 = 0
        let tagSize = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                         tagSize, &t, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                     tagSize, &t, &size, raw) == noErr else { return [] }
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        guard n > 0 else { return [] }
        return withUnsafePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeBufferPointer(
                start: UnsafeRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self),
                count: n
            ).map(\.mChannelLabel)
        }
    }

    /// What the format description tells the renderer the buffer contains.
    private func stampedChannelLabels(_ count: Int32) -> [AudioChannelLabel] {
        expandTag(audioChannelLayoutTag(for: count))
    }

    /// FFmpeg's untouched default, which is what the resampler follows for every count but 7.
    private func ffmpegDefaultOrder(_ count: Int32) -> [String] {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, count)
        defer { av_channel_layout_uninit(&layout) }
        return (0..<count).map { index in
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            var name = [CChar](repeating: 0, count: 64)
            _ = av_channel_name(&name, 64, channel)
            return String(cString: name)
        }
    }

    // MARK: - The canary

    /// If an FFmpegBuild bump ever changes what the resampler writes, this fails first and names
    /// the count, instead of the mismatch surfacing as misplaced audio nobody can trace.
    func testResamplerOrderIsWhatTheStampIsBuiltAgainst() {
        let expected: [Int32: [String]] = [
            1: ["FC"],
            2: ["FL", "FR"],
            3: ["FL", "FR", "LFE"],
            4: ["FL", "FR", "FC", "BC"],
            5: ["FL", "FR", "FC", "BL", "BR"],
            6: ["FL", "FR", "FC", "LFE", "BL", "BR"],
            7: ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"],
            8: ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        ]
        for count in Int32(1)...8 {
            XCTAssertEqual(ffmpegDefaultOrder(count), expected[count],
                           "FFmpeg's \(count)ch default order changed")
        }
        // 6.1's default is the one order no CoreAudio tag describes, so the resampler is pointed
        // somewhere else on purpose. If that stops being true, the redirect is dead weight.
        XCTAssertNotEqual(resamplerOrder(7), ffmpegDefaultOrder(7))
        XCTAssertEqual(resamplerOrder(7), ["FL", "FR", "FC", "LFE", "BL", "BR", "BC"])
        for count in Int32(1)...8 where count != 7 {
            XCTAssertEqual(resamplerOrder(count), ffmpegDefaultOrder(count),
                           "\(count)ch should follow FFmpeg's default untouched")
        }
    }

    // MARK: - The contract

    func testStampedLayoutDescribesTheChannelsTheResamplerActuallyWrote() {
        for count in Int32(1)...8 {
            let stamped = coreAudioOrder(stampedChannelLabels(count))
            // A mono track is a mono track, not a centre channel: it keeps the Mono tag, whose
            // up-mix to stereo is full gain where a Centre description would cost 3 dB.
            let expected = count == 1 ? ["MONO"] : resamplerOrder(count)
            XCTAssertEqual(stamped, expected, "\(count)ch is stamped as something else")
        }
    }

    /// Anchors the mapping against CoreAudio's own layouts wherever a tag with the same order
    /// exists, so the test cannot pass by agreeing with itself.
    func testAgreesWithCoreAudiosOwnLayoutsWhereOneMatches() {
        let anchors: [Int32: AudioChannelLayoutTag] = [
            2: kAudioChannelLayoutTag_Stereo,
            3: kAudioChannelLayoutTag_DVD_4,
            4: kAudioChannelLayoutTag_MPEG_4_0_A,
            5: kAudioChannelLayoutTag_MPEG_5_0_A,
            6: kAudioChannelLayoutTag_MPEG_5_1_A,
            7: kAudioChannelLayoutTag_AudioUnit_6_1,
        ]
        for (count, tag) in anchors {
            XCTAssertEqual(stampedChannelLabels(count), expandTag(tag),
                           "\(count)ch does not match CoreAudio's own \(tag)")
        }
    }

    // MARK: - The same contract without any naming in it

    /// Names are an argument; placement is the thing that goes wrong. This renders one channel at
    /// a time through a real downmix and asserts the stamped tag puts it exactly where a layout
    /// built from the resampler's own order puts it. It is the measurement that found #401, kept.
    func testStampedTagPlacesEveryChannelWhereTheResamplerPutIt() throws {
        for count in Int32(2)...8 {
            let truth = Self.descriptionsLayout(labelsMatching: resamplerOrder(count))
            let stamped = try XCTUnwrap(AVAudioChannelLayout(layoutTag: audioChannelLayoutTag(for: count)))
            for channel in 0..<Int(count) {
                let expected = try Self.downmixToStereo(truth, signalAt: channel)
                let actual = try Self.downmixToStereo(stamped, signalAt: channel)
                XCTAssertEqual(actual.0, expected.0, accuracy: 0.01,
                               "\(count)ch: channel \(channel) moved in the left output")
                XCTAssertEqual(actual.1, expected.1, accuracy: 0.01,
                               "\(count)ch: channel \(channel) moved in the right output")
            }
        }
    }

    private static func descriptionsLayout(labelsMatching names: [String]) -> AVAudioChannelLayout {
        let byName: [String: AudioChannelLabel] = [
            "FL": kAudioChannelLabel_Left, "FR": kAudioChannelLabel_Right,
            "FC": kAudioChannelLabel_Center, "LFE": kAudioChannelLabel_LFEScreen,
            "BL": kAudioChannelLabel_LeftSurround, "BR": kAudioChannelLabel_RightSurround,
            "BC": kAudioChannelLabel_CenterSurround,
            "SL": kAudioChannelLabel_LeftSurroundDirect, "SR": kAudioChannelLabel_RightSurroundDirect,
        ]
        let labels = names.map { byName[$0] ?? kAudioChannelLabel_Unknown }
        let size = MemoryLayout<AudioChannelLayout>.size
            + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descs = withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self)
        }
        for (i, label) in labels.enumerated() { descs[i].mChannelLabel = label }
        return AVAudioChannelLayout(layout: layout)
    }

    /// One channel at full scale through AVAudioEngine's mixer, offline so it needs no device.
    private static func downmixToStereo(_ layout: AVAudioChannelLayout,
                                        signalAt: Int) throws -> (Float, Float) {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: source)
        defer { engine.stop() }
        let frames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: frames)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames))
        input.frameLength = frames
        for channel in 0..<Int(source.channelCount) {
            for frame in 0..<Int(frames) {
                input.floatChannelData![channel][frame] = channel == signalAt ? 1.0 : 0.0
            }
        }
        try engine.start()
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                    frameCapacity: frames))
        _ = try engine.renderOffline(frames, to: output)
        var left: Float = 0, right: Float = 0
        if let data = output.floatChannelData {
            for i in 0..<Int(output.frameLength) {
                left = max(left, abs(data[0][i]))
                right = max(right, abs(data[1][i]))
            }
        }
        return (left, right)
    }
}
