import Foundation

/// RAR sets stored inside RAR sets, both holding `Movie.2021.mkv` (4007 bytes). Made by RAR 7
/// (`rar a -m0 -ma5 -ep`), the scene-style inner set written in the RAR 2.9 format and checked
/// with UnRAR 7. Each volume is Base64.
enum NestedRarFixture {
    /// A scene release, `movie.rar`, `movie.r00`, `movie.r01` (RAR 4) and `movie.nfo`, in an
    /// outer RAR 5 set of two volumes; `movie.r00` is split between them.
    static let scene: [Data] = [
        volume("""
            UmFyIRoHAQBt4SgnCwEFBwEGAQGAgIAApBEJKycCAwuUAASUAKSDAurIG6eAAAEJbW92aWUubmZvCgMTa9sJa5mJPiBTb21lIHJl
            bGVhc2Ugbm90ZXMuCgVJ1VInAgMLpQwEpQykgwJRi+WygAABCW1vdmllLnJhcgoDE2vbCWv3yTsgUmFyIRoHALLvcwEBDQAAAAAA
            AAC+cnQCgC4A3AUAAKcPAAADQhOIbhAuPFodMA4AAACkgU1vdmllLjIwMjEubWt2GkXfozRBTltodYKPnKm2w9Dd6vcEER4rOEVS
            X2x5hpOgrbrH1OHu+wgVIi88SVZjcH2Kl6SxvsvY5fL/DBkmM0BNWmd0gY6bqLXCz9zp9gMQHSo3RFFea3iFkp+sucbT4O36BxQh
            LjtIVWJvfImWo7C9ytfk8f4LGCUyP0xZZnOAjZqntMHO2+j1Ag8cKTZDUF1qd4SRnqu4xdLf7PkGEyAtOkdUYW57iJWir7zJ1uPw
            /QoXJDE+S1hlcn+MmaazwM3a5/QBDhsoNUJPXGl2g5CdqrfE0d7r+AUSHyw5RlNgbXqHlKGuu8jV4u/8CRYjMD5LWGVyf4yZprPA
            zdrn9AEOGyg1Qk9caXaDkJ2qt8TR3uv4BRIfLDlGU2BteoeUoa67yNXi7/wJFiMwPUpXZHF+i5ilsr/M2ebzAA0aJzRBTltodYKP
            nKm2w9Dd6vcEER4rOEVSX2x5hpOgrbrH1OHu+wgVIi88SVZjcH2Kl6SxvsvY5fL/DBkmM0BNWmd0gY6bqLXCz9zp9gMQHSo3RFFe
            a3iFkp+sucbT4O36BxQhLjtIVWJvfImWo7C9ytfk8f4LGCUyP0xZZnOAjZqntMHO2+j1Ag8cKTZDUF1qd4SRnqu4xdLf7PkGEyAt
            OkdUYW58iZajsL3K1+Tx/gsYJTI/TFlmc4CNmqe0wc7b6PUCDxwpNkNQXWp3hJGeq7jF0t/s+QYTIC06R1RhbnuIlaKvvMnW4/D9
            ChckMT5LWGVyf4yZprPAzdrn9AEOGyg1Qk9caXaDkJ2qt8TR3uv4BRIfLDlGU2BteoeUoa67yNXi7/wJFiMwPUpXZHF+i5ilsr/M
            2ebzAA0aJzRBTltodYKPnKm2w9Dd6vcEER4rOEVSX2x5hpOgrbrH1OHu+wgVIi88SVZjcH2Kl6SxvsvY5fL/DBkmM0BNWmd0gY6b
            qLXCz9zp9gMQHSo3RFFea3iFkp+susfU4e77CBUiLzxJVmNwfYqXpLG+y9jl8v8MGSYzQE1aZ3SBjpuotcLP3On2AxAdKjdEUV5r
            eIWSn6y5xtPg7foHFCEuO0hVYm98iZajsL3K1+Tx/gsYJTI/TFlmc4CNmqe0wc7b6PUCDxwpNkNQXWp3hJGeq7jF0t/s+QYTIC06
            R1RhbnuIlaKvvMnW4/D9ChckMT5LWGVyf4yZprPAzdrn9AEOGyg1Qk9caXaDkJ2qt8TR3uv4BRIfLDlGU2BteoeUoa67yNXi7/wJ
            FiMwPUpXZHF+i5ilsr/M2ebzAA0aJzRBTltodYKPnKm2w9Dd6vgFEh8sOUZTYG16h5ShrrvI1eLv/AkWIzA9SldkcX6LmKWyv8zZ
            5vMADRonNEFOW2h1go+cqbbD0N3q9wQRHis4RVJfbHmGk6CtusfU4e77CBUiLzxJVmNwfYqXpLG+y9jl8v8MGSYzQE1aZ3SBjpuo
            tcLP3On2AxAdKjdEUV5reIWSn6y5xtPg7foHFCEuO0hVYm98iZajsL3K1+Tx/gsYJTI/TFlmc4CNmqe0wc7b6PUCDxwpNkNQXWp3
            hJGeq7jF0t/s+QYTIC06R1RhbnuIlaKvvMnW4/D9ChckMT5LWGVyf4yZprPAzdrn9AEOGyg2Q1BdaneEkZ6ruMXS3+z5BhMgLTpH
            VGFue4iVoq+8ydbj8P0KFyQxPktYZXJ/jJmms8DN2uf0AQ4bKDVCT1xpdoOQnaq3xNHe6/gFEh8sOUZTYG16h5ShrrvI1eLv/AkW
            IzA9SldkcX6LmKWyv8zZ5vMADRonNEFOW2h1go+cqbbD0N3q9wQRHis4RVJfbHmGk6CtusfU4e77CBUiLzxJVmNwfYqXpLG+y9jl
            8v8MGSYzQE1aZ3SBjpuotcLP3On2AxAdKjdEUV5reIWSn6y5xtPg7foHFCEuO0hVYm98iZajsL3K1+Tx/gsYJTI/TFlmdIGOm6i1
            ws/c6fYDEB0qN0RRXmt4hZKfrLnG0+Dt+gcUIS47SFVib3yJlqOwvcrX5PH+CxglYdd7AQAHAOnsyIcnAhML+gUEpQykgwK/Ypms
            gAABCW1vdmllLnIwMAoDE2vbCWsbgz0gUmFyIRoHAPH7cwEADQAAAAAAAABdU3QDgC4A3AUAAKcPAAAD26/hmRAuPFodMA4AAACk
            gU1vdmllLjIwMjEubWt2Mj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6ruMXS3+z5BhMgLTpHVGFue4iVoq+8ydbj8P0KFyQx
            PktYZXJ/jJmms8DN2uf0AQ4bKDVCT1xpdoOQnaq3xNHe6/gFEh8sOUZTYG16h5ShrrvI1eLv/AkWIzA9SldkcX6LmKWyv8zZ5vMA
            DRonNEFOW2h1go+cqbbD0N3q9wQRHis4RVJfbHmGk6CtusfU4e77CBUiLzxJVmNwfYqXpLK/zNnm8wANGic0QU5baHWCj5yptsPQ
            3er3BBEeKzhFUl9seYaToK26x9Th7vsIFSIvPElWY3B9ipeksb7L2OXy/wwZJjNATVpndIGOm6i1ws/c6fYDEB0qN0RRXmt4hZKf
            rLnG0+Dt+gcUIS47SFVib3yJlqOwvcrX5PH+CxglMj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6ruMXS3+z5BhMgLTpHVGFu
            e4iVoq+8ydbj8P0KFyQxPktYZXJ/jJmms8DN2uf0AQ4bKDVCT1xpdoOQnaq3xNHe6/gFEh8sOUZTYG16h5ShrrvI1eLw/QoXJDE+
            S1hlcn+MmaazwM3a5/QBDhsoNUJPXGl2g5CdqrfE0d7r+AUSHyw5RlNgbXqHlKGuu8jV4u/8CRYjMD1KV2RxfouYpbK/zNnm8wAN
            Gic0QU5baHWCj5yptsPQ3er3BBEeKzhFUl9seYaToK26x9Th7vsIFSIvPElWY3B9ipeksb7L2OXy/wwZJjNATVpndIGOm6i1ws/c
            6fYDEB0qN0RRXmt4hZKfrLnG0+Dt+gcUIS47SFVib3yJlqOwvcrX5PH+CxglMj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6r
            uMXS3+z5BhMgLjtIVWJvfImWo7C9ytfk8f4LGCUyP0xZZnOAi0dRJgMFBAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            """),
        volume("""
            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
            """),
    ]

    /// `Movie.2021.part1.rar` … `part4.rar` (RAR 5, password "secret") in an outer RAR 5 set of
    /// two volumes.
    static let encrypted: [Data] = [
        volume("""
            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
            """),
        volume("""
            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
            """),
    ]

    /// The file both inner sets hold.
    static let content: Data = {
        var bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        for i in 4..<4007 { bytes.append(UInt8((i * 13 + i / 241) & 0xFF)) }
        return Data(bytes)
    }()

    private static func volume(_ base64: String) -> Data {
        Data(base64Encoded: base64.filter { !$0.isWhitespace })!
    }
}
