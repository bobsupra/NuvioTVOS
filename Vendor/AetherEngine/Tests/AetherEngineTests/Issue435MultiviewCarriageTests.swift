import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#435: a 3D Blu-ray MVC remux carries both eyes inside one H.264 track. Matroska calls that
/// StereoMode 13 / 14 (`block_lr` / `block_rl`, both eyes in one block) and libavformat reports it as
/// stream-level `AV_PKT_DATA_STEREO3D` of type `AV_STEREO3D_FRAMESEQUENCE`. The dependent view's slices
/// reference a subset SPS the base decoder never sees, so a plain H.264 decoder has to skip them.
/// libavcodec does exactly that and decodes the base view, which is the left eye and the 2D fallback
/// every non-3D player shows. VideoToolbox is handed whole samples with both views' NALs inside and
/// renders nothing: reported as black video with the audio playing.
///
/// What these fixtures carry is the CONTAINER DECLARATION, not an MVC bitstream (no encoder in the
/// build produces one), and that is the whole input of the rule under test: routing reads the
/// declaration, at load, before a packet is decoded. The decode half of the report is libavcodec's
/// documented behaviour and was measured by the reporter with ffmpeg on the real file.
@Suite("AE#435: both stereo views in one H.264 track route to software")
struct Issue435MultiviewCarriageTests {

    private static func openFixture(_ base64: String) throws -> Demuxer {
        let demuxer = Demuxer()
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        return demuxer
    }

    // MARK: - The decision, end to end on one file

    @Test("block_lr reaches the routing policy as frame sequence and takes the software path")
    func blockLREndsUpOnSoftware() throws {
        let demuxer = try Self.openFixture(Self.blockLRBase64)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)

        // The fixture carries the case: H.264, progressive, and the container's stereo declaration.
        #expect(codecpar.pointee.codec_id == AV_CODEC_ID_H264)
        let stereo = AetherEngine.stereo3DType(stream: stream)
        #expect(stereo == AV_STEREO3D_FRAMESEQUENCE)

        // Without the declaration this stream is native (progressive H.264), so the rule is what moves it.
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: codecpar.pointee.codec_id,
            fieldOrder: codecpar.pointee.field_order,
            av1Available: true))
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: codecpar.pointee.codec_id,
            fieldOrder: codecpar.pointee.field_order,
            av1Available: true,
            stereo3DType: stereo))
    }

    @Test("a frame-packed declaration keeps hardware decode")
    func sideBySideStaysNative() throws {
        let demuxer = try Self.openFixture(Self.sideBySideBase64)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)

        // Side by side is one self-contained picture. It decodes natively; whether to crop an eye out
        // of it is the host's call, and paying a software decode for it would buy nothing.
        let stereo = AetherEngine.stereo3DType(stream: stream)
        #expect(stereo == AV_STEREO3D_SIDEBYSIDE)
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: codecpar.pointee.codec_id,
            fieldOrder: codecpar.pointee.field_order,
            av1Available: true,
            stereo3DType: stereo))
    }

    // MARK: - The rule in isolation

    @Test("only the two both-eyes-in-one-track carriages qualify")
    func onlyFrameSequenceQualifies() {
        #expect(VideoRoutingPolicy.routesSoftwareForMultiviewCarriage(
            codecID: AV_CODEC_ID_H264, stereo3DType: AV_STEREO3D_FRAMESEQUENCE))
        for packed in [AV_STEREO3D_2D, AV_STEREO3D_SIDEBYSIDE, AV_STEREO3D_TOPBOTTOM,
                       AV_STEREO3D_CHECKERBOARD, AV_STEREO3D_LINES, AV_STEREO3D_COLUMNS,
                       AV_STEREO3D_SIDEBYSIDE_QUINCUNX] {
            #expect(!VideoRoutingPolicy.routesSoftwareForMultiviewCarriage(
                codecID: AV_CODEC_ID_H264, stereo3DType: packed))
        }
        // A stream that declares nothing is the overwhelming majority; it must not pay for this rule.
        #expect(!VideoRoutingPolicy.routesSoftwareForMultiviewCarriage(
            codecID: AV_CODEC_ID_H264, stereo3DType: nil))
    }

    @Test("HEVC keeps the native path: MV-HEVC is Apple's own format and plays its base layer")
    func hevcIsExempt() {
        #expect(!VideoRoutingPolicy.routesSoftwareForMultiviewCarriage(
            codecID: AV_CODEC_ID_HEVC, stereo3DType: AV_STEREO3D_FRAMESEQUENCE))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
            stereo3DType: AV_STEREO3D_FRAMESEQUENCE))
    }

    // MARK: - Fixtures

    /// 5 frames of 64x64 H.264 in Matroska, StereoMode 13 (`block_lr`).
    /// `ffmpeg -f lavfi -i testsrc2=size=64x64:rate=25 -frames:v 5 -c:v libx264 -preset ultrafast
    ///  -qp 40 -pix_fmt yuv420p -metadata:s:v:0 stereo_mode=block_lr -f matroska`
    private static let blockLRBase64 = """
GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAJBRFNm3TAv4T3OsbYTbuLU6uEFUmp
ZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIBi027jFOrhBxTu2tTrIII6ewBAAAAAAAAUwAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmp
Zsu/hOkxw28q17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJCZg1gJ8oHCfNqZC90DJpO0RImIQGkA
AAAAAAAWVK5rQJS/hF5ujWeuAQAAAAAAAIXXgQFzxYj2w+uAyOPR05yBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OB
ASPjg4QCYloA4JSwgUC6gUCagQJTuIENVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOipgFCwAr/4QAWZ0LACtoQmwEQAAADABAA
AAMDIPEiagEABWjOA5yAElTDZ0CDv4QrZCKGc3OgY8CAZ8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDFzc9djwItjxYj2
w+uAyOPR02fIokWjh0VOQ09ERVJEh5VMYXZjNjIuMjguMTAxIGxpYngyNjRnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIw
MDAwMDAwMAAfQ7Z1Rs+/hDgrecnngQCjRUOBAACAAAACLAYF//8o3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSBy
MzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cu
dmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6
MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9t
ZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNl
dD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVy
bGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0y
NTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcXAgbWJ0cmVlPTAgcXA9NDAgaXBfcmF0
aW89MS40MCBhcT0wAIAAAAMLZYiEOgxgBkxHhuAV91g5xdl4Ax658+wmZPCZbG3P/hu29/8C51rIPC7c2Uhvod3sPHWtB6Jz
x2WRnKHZYEExihigFAJs4iHBTaaGDni1FZDhuAT1ilZNIOUrl0RWQXUAztmKk3338PDSGJ7XT6Hquh+ZPmQ6qWAna14+le0w
9RA82GTZsuuka8ZdVqAGGx1pIPGZoyqrR75MjdvAzYSnJmq55ZrvZQxtzjdR+qa/zjMgqcZ/H09+gYta1+/oGMARRtq9gYH/
f0aYxde6fYY8ufPsmJJkYuvdPt7XvPPNLWWecarHUN9HHuxRDfRXvMPEJsPNmz0N9ITeg6hAACAGQigBpuClTQqFc6nkUNFT
Q0s/ecO2AkYZ2mFtthuE3/cfvOAuoDAxmE6X7mFnoR7ej3Bdi3F7n3EbvfcCDNZ5W0PB6PikHUZmyFDbcd2Ph460PB5+cxVD
bm5yFENuDUcIJ0La5MSGMr0dPf2hHSVjamEXzmTJf8qBsUeVOcOu5W/YZs3DamGHAKHoAAQA4+F/E2P/n2J9j4iCiEd5gXI5
gXJzEuYJzcC6vpH///7+I0QTX9y/n83C6tx9Buu5////BIQHS/y23fDjTC6r0kX///f8FKDSf/8mXGmUqQ7hsCzgDBcdMGoI
13G+OTOITIgEycsZyx8AUMAcNdorqFFx5YEzJ3vFOaWKghZ3HwsBfABdORmTAYooV4ZGlnJkQmZwsRAsfCQRAcGGBiqgPZSy
cA3MxtaYPkApLmFnABibcCo5ahtt7YKtS8Eb58t6a9OmEC5gwPTDqHLKzl7BgtAI9fa1l4z/mAzgBD2m8U3uTTaZOTKaZyZa
ZTcGBl8cZL5GaQpQRhkK3LdRQmSzXPQzOWMqSeUXwLaLtiURKuwpwGrW6PBKTCEiPwdEx4OhMCnAm/JdBU2ESGvB42PB4bEL
OANVGRHHvEr+P6nZoPU1usPHd9g7vsImyCC6pCfBi665IzQxeHOO4FsAoAMkOl3Q2BoeWOKOViViKOKMH7CQIYf0qq5mR1Fg
ZATjXOCj4YEAKAAAAABZQZoihPDk3m9AR/gck7nniwFywPfc8Pfc/C/liYAAceTO/48mZixeT4c59G1QZj+I/5p+Qfm1NOv/
48NTeb0An4ck7n88UMAIe+58Pfc/56/Quv/nr9qY/4Cj2YEAUAAAAABRQZpCvPDfZCDRHLyBrT8GVL6KfnuP1HAaF8ORkfDr
R9a/wS7P7nw5w4PaK3/IweO9CAMTr+56fDU1oHGtLeLX4Y97u/hrhp7sfLUMQKfu51n4o/iBAHgAAAAAcEGaYrzwLWSAgXRt
8Cl9LhBwp5/xHDkR8R8VsCr/g0TuYRhnx5WfHbFdH80Kw0dgf+HONryKl8diQDfedIx3znBbw1EfEfFrCu/lRO58Iw3g6vB1
eADfo4Nnc+IBFH5e26U+GuEb0unH2xBtf3y3n4CjxoEAoAAAAAA+QZqCj9Wvqw8F1dWMSqAz7ceG76eH8Aquvdz3w1PQAGNF
ZrFvhwlCf4ajeRM49CbSY13iMs3eBa2l5ZvvP+AcU7trl7+E6xFLoLuPs4EAt4r3gQHxggIU8IEJ
"""

    /// The same clip declared `left_right` (StereoMode 1), the frame-packed control.
    private static let sideBySideBase64 = """
GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAJDRFNm3TAv4RwA55eTbuLU6uEFUmp
ZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIBk027jFOrhBxTu2tTrIII8ewBAAAAAAAAUwAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmp
Zsu/hPbGjbUq17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJCEFNES80kIH+LpCLo/pOTuRImIQGkA
AAAAAAAWVK5rQJy/hFZnqNquAQAAAAAAAI3XgQFzxYjapQhke+mLWJyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OB
ASPjg4QCYloA4JywgUC6gUCagQJTuIEBVLCBIFS6gUBVsIRVuYEBVe6BAOwBAAAAAAAAAgAAY6KmAULACv/hABZnQsAK2hCb
ARAAAAMAEAAAAwMg8SJqAQAFaM4DnIASVMNnQIO/hGxiQyJzc6BjwIBnyJpFo4dFTkNPREVSRIeNTGF2ZjYyLjEyLjEwMXNz
12PAi2PFiNqlCGR76YtYZ8iiRaOHRU5DT0RFUkSHlUxhdmM2Mi4yOC4xMDEgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6
MDA6MDAuMjAwMDAwMDAwAB9DtnVGz7+EOCt5yeeBAKNFQ4EAAIAAAAIsBgX//yjcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNv
cmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0
cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFu
YWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYg
Y2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFf
cXBfb2Zmc2V0PTAgdGhyZWFkcz0yIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRl
PTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAg
a2V5aW50PTI1MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNxcCBtYnRyZWU9MCBxcD00
MCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAwtliIQ6DGAGTEeG4BX3WDnF2XgDHrnz7CZk8Jlsbc/+G7b3/wLnWsg8LtzZSG+h
3ew8da0HonPHZZGcodlgQTGKGKAUAmziIcFNpoYOeLUVkOG4BPWKVk0g5SuXRFZBdQDO2YqTfffw8NIYntdPoeq6H5k+ZDqp
YCdrXj6V7TD1EDzYZNmy66Rrxl1WoAYbHWkg8ZmjKqtHvkyN28DNhKcmarnlmu9lDG3ON1H6pr/OMyCpxn8fT36Bi1rX7+gY
wBFG2r2Bgf9/RpjF17p9hjy58+yYkmRi690+3te8880tZZ5xqsdQ30ce7FEN9Fe8w8Qmw82bPQ30hN6DqEAAIAZCKAGm4KVN
CoVzqeRQ0VNDSz95w7YCRhnaYW22G4Tf9x+84C6gMDGYTpfuYWehHt6PcF2LcXufcRu99wIM1nlbQ8Ho+KQdRmbIUNtx3Y+H
jrQ8Hn5zFUNubnIUQ24NRwgnQtrkxIYyvR09/aEdJWNqYRfOZMl/yoGxR5U5w67lb9hmzcNqYYcAoegABADj4X8TY/+fYn2P
iIKIR3mBcjmBcnMS5gnNwLq+kf///v4jRBNf3L+fzcLq3H0G67n///8EhAdL/Lbd8ONMLqvSRf//9/wUoNJ//yZcaZSpDuGw
LOAMFx0wagjXcb45M4hMiATJyxnLHwBQwBw12iuoUXHlgTMne8U5pYqCFncfCwF8AF05GZMBiihXhkaWcmRCZnCxECx8JBEB
wYYGKqA9lLJwDczG1pg+QCkuYWcAGJtwKjlqG23tgq1LwRvny3pr06YQLmDA9MOocsrOXsGC0Aj19rWXjP+YDOAEPabxTe5N
Npk5MppnJlplNwYGXxxkvkZpClBGGQrct1FCZLNc9DM5YypJ5RfAtou2JREq7CnAatbo8EpMISI/B0THg6EwKcCb8l0FTYRI
a8HjY8HhsQs4A1UZEce8Sv4/qdmg9TW6w8d32Du+wibIILqkJ8GLrrkjNDF4c47gWwCgAyQ6XdDYGh5Y4o5WJWIo4owfsJAh
h/SqrmZHUWBkBONc4KPhgQAoAAAAAFlBmiKE8OTeb0BH+ByTueeLAXLA99zw99z8L+WJgABx5M7/jyZmLF5Phzn0bVBmP4j/
mn5B+bU06//jw1N5vQCfhyTufzxQwAh77nw99z/nr9C6/+ev2pj/gKPZgQBQAAAAAFFBmkK88N9kINEcvIGtPwZUvop+e4/U
cBoXw5GR8OtH1r/BLs/ufDnDg9orf8jB470IAxOv7np8NTWgca0t4tfhj3u7+GuGnux8tQxAp+7nWfij+IEAeAAAAABwQZpi
vPAtZICBdG3wKX0uEHCnn/EcORHxHxWwKv+DRO5hGGfHlZ8dsV0fzQrDR2B/4c42vIqXx2JAN950jHfOcFvDUR8R8WsK7+VE
7nwjDeDq8HV4AN+jg2dz4gEUfl7bpT4a4RvS6cfbEG1/fLefgKPGgQCgAAAAAD5BmoKP1a+rDwXV1YxKoDPtx4bvp4fwCq69
3PfDU9AAY0VmsW+HCUJ/hqN5Ezj0JtJjXeIyzd4FraXlm+8/4BxTu2uXv4QEOf9lu4+zgQC3iveBAfGCAhzwgQk=
"""
}
