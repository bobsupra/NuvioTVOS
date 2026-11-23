import Testing
import AetherLibavcodec
import AetherLibavutil

/// Proves the DTS:X height patch (build.sh `patch_ffmpeg_dca_x_heights`,
/// patches/dca-xll-x-heights.patch) is in the shipped libavcodec.
///
/// The patch adds the `dca` decoder option `x_heights`, off by default. With it the
/// decoder reads the height channel set of DTS:X's standard presentation and outputs
/// 7.1.4 (AetherEngine #798). An option avcodec_open2() does not know stays in the
/// dictionary it was handed, so a build without the patch is told apart by that alone.
/// The decode itself is measured in AetherEngine against real DTS:X streams, which
/// cannot be committed here.
struct DTSXHeightsOptionTests {

    @Test("the dca decoder takes x_heights, and it is off by default")
    func optionExists() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_DTS))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        var value: Int64 = -1
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_heights", 0, &value) >= 0)
        #expect(value == 0)

        var options: OpaquePointer?
        av_dict_set(&options, "x_heights", "1", 0)
        defer { av_dict_free(&options) }
        #expect(avcodec_open2(context, codec, &options) >= 0)
        #expect(av_dict_get(options, "x_heights", nil, 0) == nil, "the decoder consumed the option")
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_heights", 0, &value) >= 0)
        #expect(value == 1)
    }

    @Test("the dca decoder exports x_presentation, read-only and 0 before any heights decoded")
    func presentationIsExported() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_DTS))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        #expect(avcodec_open2(context, codec, nil) >= 0)
        var value: Int64 = -1
        #expect(av_opt_get_int(context!.pointee.priv_data, "x_presentation", 0, &value) >= 0)
        #expect(value == 0)
        #expect(av_opt_set_int(context!.pointee.priv_data, "x_presentation", 1, 0) < 0, "read-only")
    }
}
