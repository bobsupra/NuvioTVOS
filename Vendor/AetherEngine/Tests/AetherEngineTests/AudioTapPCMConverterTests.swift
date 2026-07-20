import XCTest
import AVFAudio
import CoreMedia
@testable import AetherEngine

/// #95 SW path: AudioDecoder emits interleaved Float32 CMSampleBuffers; the converter turns
/// them into tap-format buffers and tracks PTS continuity across calls.
final class AudioTapPCMConverterTests: XCTestCase {

    /// Interleaved Float32 stereo CMSampleBuffer at 44.1 kHz, constant value, with a given PTS.
    private func makeSample(seconds: Double, pts: Double, sampleRate: Double = 44_100,
                            channels: UInt32 = 2) throws -> CMSampleBuffer {
        let frames = Int(seconds * sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
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
}
