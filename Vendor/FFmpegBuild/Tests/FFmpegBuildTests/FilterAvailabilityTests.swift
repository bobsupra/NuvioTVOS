import Testing
import AetherLibavfilter

/// Proves the zscale + tonemap filters (and the graph endpoints) are
/// actually compiled into the shipped libavfilter. `avfilter_get_by_name`
/// returns non-nil only when the filter was enabled at configure time. If a
/// future build drops `--enable-filter=zscale`, the HDR tone-map path that
/// depends on this silently breaks; this test catches it.
struct FilterAvailabilityTests {

    @Test("zscale filter is available")
    func zscaleAvailable() {
        #expect(avfilter_get_by_name("zscale") != nil)
    }

    @Test("tonemap filter is available")
    func tonemapAvailable() {
        #expect(avfilter_get_by_name("tonemap") != nil)
    }

    @Test("graph endpoint + support filters are available")
    func endpointsAvailable() {
        #expect(avfilter_get_by_name("buffer") != nil)
        #expect(avfilter_get_by_name("buffersink") != nil)
        #expect(avfilter_get_by_name("format") != nil)
        #expect(avfilter_get_by_name("colorspace") != nil)
    }

    @Test("deinterlacers are available")
    func deinterlacersAvailable() {
        // AetherEngine's software-decode path deinterlaces interlaced
        // MPEG-2 / VC-1 / MPEG-4 through bwdif (yadif fallback); if a
        // future build drops them the engine silently renders combing.
        #expect(avfilter_get_by_name("bwdif") != nil)
        #expect(avfilter_get_by_name("yadif") != nil)
    }

    @Test("inverse telecine filters are available")
    func inverseTelecineAvailable() {
        // AetherEngine#853 detects telecine with idet and undoes it with
        // fieldmatch + decimate; without them 3:2 film stays at 29.97.
        for name in ["idet", "fieldmatch", "decimate"] {
            #expect(avfilter_get_by_name(name) != nil, "\(name) missing")
        }
    }

    @Test("audio shaping filters are available")
    func audioShapingAvailable() {
        // AetherEngine#923 builds one graph after its resampler: the stereo
        // dialogue lift, night mode and the lookahead limiter. Without any one
        // of them the graph fails to configure and the engine plays the audio
        // without its dynamics.
        for name in ["abuffer", "abuffersink", "aformat", "aresample", "pan",
                     "dialoguenhance", "acompressor", "alimiter"] {
            #expect(avfilter_get_by_name(name) != nil, "\(name) missing")
        }
    }
}
