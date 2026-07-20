import Foundation

/// FFmpeg error sentinels whose C macros (`AVERROR_EOF`, `AVERROR(EAGAIN)`, `AVERROR_INVALIDDATA`) Swift cannot import directly.
enum FFmpegErr {
    /// `AVERROR_EOF` = FFERRTAG('E','O','F',' ') = -0x20464F45 = -541478725.
    static let eof: Int32 = -0x20464F45
    /// `AVERROR(EAGAIN)`; EAGAIN is POSIX 35 on Apple platforms.
    static let eagain: Int32 = -35
    /// `AVERROR_INVALIDDATA` = FFERRTAG('I','N','D','A') = -0x41444E49.
    static let invalidData: Int32 = -0x41444E49
    /// `AVERROR(EINVAL)`; EINVAL is POSIX 22 on Apple platforms. Some decoders (notably `dca` on a
    /// DTS-HD MA XLL frame that residual-codes channels without a usable core) reject a single packet
    /// with this while staying usable for the next one (#64).
    static let einval: Int32 = -22
}
