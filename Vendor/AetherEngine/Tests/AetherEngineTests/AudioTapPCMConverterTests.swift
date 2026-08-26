import XCTest
import AVFAudio
import CoreMedia
@testable import AetherEngine

/// #95 SW path: AudioDecoder emits interleaved Float32 CMSampleBuffers; the converter turns
/// them into tap-format buffers and tracks PTS continuity across calls.
final class AudioTapPCMConverterTests: XCTestCase {

    /// Interleaved Float32 CMSampleBuffer at a given rate/channel count, constant value, with a
    /// given PTS. `layoutTag` mirrors AudioDecoder, which always attaches a layout to its format
    /// description; pass nil for the defensive case of a description that carries none.
    private func makeSample(seconds: Double, pts: Double, sampleRate: Double = 44_100,
                            channels: UInt32 = 2,
                            layoutTag: AudioChannelLayoutTag? = nil) throws -> CMSampleBuffer {
        let frames = Int(seconds * sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        if let layoutTag {
            var layout = AudioChannelLayout(mChannelLayoutTag: layoutTag, mChannelBitmap: [],
                                            mNumberChannelDescriptions: 0,
                                            mChannelDescriptions: AudioChannelDescription())
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                           layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                           layout: &layout,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
        } else {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
        }
        let data = [Float](repeating: 0.25, count: frames * Int(channels))
        var block: CMBlockBuffer?
        let byteCount = data.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    func testConvertsToTapFormatAndKeepsPTS() throws {
        let conv = AudioTapPCMConverter()
        let out1 = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        XCTAssertFalse(out1.isEmpty)
        XCTAssertTrue(out1[0].discontinuity)                      // first buffer after install
        XCTAssertEqual(out1[0].sourceTime, 12.0, accuracy: 0.01)
        let out2 = conv.convert(try makeSample(seconds: 0.5, pts: 12.5))
        // The SRC keeps a small in-flight window per call (samples are delayed into the next
        // call, not lost): assert the cumulative output over two calls, minus that window.
        let total = (out1 + out2).reduce(0) { $0 + Int($1.buffer.frameLength) }
        XCTAssertGreaterThan(total, 44_000)                       // ~1.0 s at 48 kHz
        XCTAssertLessThanOrEqual(total, 48_000)
        for b in out1 + out2 {
            XCTAssertEqual(b.buffer.format.sampleRate, 48_000)
            XCTAssertEqual(b.buffer.format.channelCount, 1)
        }
    }

    func testContiguousBuffersDoNotFlagDiscontinuity() throws {
        let conv = AudioTapPCMConverter()
        _ = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 12.5))
        XCTAssertFalse(out.contains { $0.discontinuity })
    }

    func testPTSJumpFlagsDiscontinuity() throws {
        let conv = AudioTapPCMConverter()
        _ = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 90.0))   // SW seek
        XCTAssertTrue(out[0].discontinuity)
    }

    /// #400: AudioDecoder emits the source channel count (up to 7.1) without downmixing, so a
    /// multichannel track on the software path hands the converter 3-8 interleaved channels.
    func testDownmixesEveryDecoderChannelCountToMonoTap() throws {
        for channels: UInt32 in 1...8 {
            let conv = AudioTapPCMConverter()
            let tag = audioChannelLayoutTag(for: Int32(channels))
            let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                                  channels: channels, layoutTag: tag))
            XCTAssertFalse(out.isEmpty, "no tap buffer for \(channels)ch input")
            for b in out {
                XCTAssertEqual(b.buffer.format.channelCount, 1)
                XCTAssertEqual(b.buffer.format.sampleRate, 48_000)
            }
            // A downmix that yields buffers of silence is as useless to the tap consumers as
            // no buffers at all, so assert the signal survived the layout mapping.
            XCTAssertGreaterThan(peak(out), 0.05, "\(channels)ch downmix is silent")
        }
    }

    /// The same input with no channel layout on the format description must not trap either.
    func testMultichannelWithoutChannelLayoutStillConverts() throws {
        let conv = AudioTapPCMConverter()
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                              channels: 6, layoutTag: nil))
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(out[0].buffer.format.channelCount, 1)
        XCTAssertGreaterThan(peak(out), 0.05)
    }

    /// The other measured silent class: a discrete layout has no mixdown matrix at any channel
    /// count, so the tap has to fold it itself rather than yield buffers of zeroes.
    func testDiscreteLayoutStillCarriesSignal() throws {
        let conv = AudioTapPCMConverter()
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                              channels: 6,
                                              layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6))
        XCTAssertFalse(out.isEmpty)
        XCTAssertGreaterThan(peak(out), 0.05)
    }

    /// The byte copy assumes packed interleaved Float32; anything else is skipped, not misread.
    func testNonFloatInputIsSkipped() throws {
        let conv = AudioTapPCMConverter()
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        let frames = 1024
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                                   dataLength: byteCount)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        XCTAssertTrue(conv.convert(sample!).isEmpty)
    }

    private func peak(_ buffers: [AudioTapBuffer]) -> Float {
        buffers.reduce(Float(0)) { acc, b in
            guard let ch = b.buffer.floatChannelData?[0] else { return acc }
            return (0..<Int(b.buffer.frameLength)).reduce(acc) { max($0, abs(ch[$1])) }
        }
    }
}
