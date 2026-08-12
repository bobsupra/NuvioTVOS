import Testing
@testable import AetherEngine

/// `SoftwarePlaybackHost.shouldFoldTimeline`: when the SW demux loop folds PTS discontinuities
/// into one continuous timeline. Live always folded; a forward-only non-live source now folds
/// too - IPTV timeshift archives are chunked recordings whose every chunk restarts at PTS ~0
/// (device trace: an 89 s chunk ending at raw 2717.9 s, the next chunk opening at 0.04 s;
/// FFmpeg's 33-bit wrap correction read that as +92726 s, the renderer waited 25 h for the
/// frame's display time and died with -12080).
@Suite("SW timeline fold decision")
struct SWTimelineFoldTests {

    @Test("forward-only VOD folds PTS discontinuities like live; seekable VOD does not")
    func timelineFoldDecision() {
        #expect(SoftwarePlaybackHost.shouldFoldTimeline(isLive: false, sourceSeekable: false) == true)
        #expect(SoftwarePlaybackHost.shouldFoldTimeline(isLive: true, sourceSeekable: true) == true)
        #expect(SoftwarePlaybackHost.shouldFoldTimeline(isLive: true, sourceSeekable: false) == true)
        // A seekable file's container timeline is trusted; threshold-sized jumps there are
        // seek artifacts the native path also leaves alone.
        #expect(SoftwarePlaybackHost.shouldFoldTimeline(isLive: false, sourceSeekable: true) == false)
    }
}
