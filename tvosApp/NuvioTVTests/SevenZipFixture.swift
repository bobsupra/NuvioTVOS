import Foundation

/// 7z archives made by 7-Zip 23 (`7z a -m0=Copy -v1500b`) holding `Movie.2021.mkv` (4007 bytes) and
/// `Movie.2021.nfo`, and an LZMA stream. Each volume is Base64.
enum SevenZipFixture {
    /// Stored, in three volumes; the file list is LZMA-compressed.
    static let stored: [Data] = [
        volume("""
            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
            """),
        volume("""
            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
            """),
        volume("""
            xNHe6/gFEh8sOUZTYG16h5ShrrvI1eLv/AkWIzA9SldkcX6LmKWyv8zZ5vMADRonNEFOW2h1go+cqbbD0N3q9wQRHis4RVJfbHmG
            k6CtusfU4e77CBUiLzxJVmNwfYqXpLG+y9jl8v8MGSYzQE1aZ3SBjpuotcLP3On2AxAdKjdEUV5reIWSn6y5xtPg7foHFCEuO0hV
            Ym98iZajsL3K1+Tx/gsYJjNATVpndIGOm6i1ws/c6fYDEB0qN0RRXmt4hZKfrLnG0+Dt+gcUIS47SFVib3yJlqOwvcrX5PH+Cxgl
            Mj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6ruMXS3+z5BhMgLTpHVGFue4iVoq+8ydbj8P0KFyQxPktYZXJ/jJmms8DN2uf0
            AQ4bKDVCT1xpdoOQnaq3xNHe6/gFEh8sOUZTYG16h5ShrrvI1eLv/AkWIzA9SldkcX6LmKWyv8zZ5vMADRonNEFOW2h1go+cqbbD
            0N3q9wQRHis4RVJfbHmGk6CtusfU4e77CBUiLzxJVmRxfouYpbK/zNnm8wANGic0QU5baHWCj5yptsPQ3er3BBEeKzhFUl9seYaT
            oK26x9Th7vsIFSIvPElWY3B9ipeksb7L2OXy/wwZJjNATVpndIGOm6i1ws/c6fYDEB0qN0RRXmt4hZKfrLnG0+Dt+gcUIS47SFVi
            b3yJlqOwvcrX5PH+CxglMj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6ruMXS3+z5BhMgLTpHVGFue4iVoq+8ydbj8P0KFyQx
            PktYZXJ/jJmms8DN2uf0AQ4bKDVCT1xpdoOQnaq3xNHe6/gFEh8sOUZTYG16h5Sir7zJ1uPw/QoXJDE+S1hlcn+MmaazwM3a5/QB
            DhsoNUJPXGl2g5CdqrfE0d7r+AUSHyw5RlNgbXqHlKGuu8jV4u/8CRYjMD1KV2RxfouYpbK/zNnm8wANGic0QU5baHWCj5yptsPQ
            3er3BBEeKzhFUl9seYaToK26x9Th7vsIFSIvPElWY3B9ipeksb7L2OXy/wwZJjNATVpndIGOm6i1ws/c6fYDEB0qN0RRXmt4hZKf
            rLnG0+Dt+gcUIS47SFVib3yJlqOwvcrX5PH+CxglMj9MWWZzgI2ap7TBztvo9QIPHCk2Q1BdaneEkZ6ruMXS4O36BxQhLjtIVWJv
            fImWo7C9ytfk8f4LGCUyP0xZZnOAjZqntMHO2+j1Ag8cKTZDUF1qd4SRnqu4xdLf7PkGEyAtOkdUYW57iJWir7zJ1uPw/QoXJDE+
            S1hlcn+MmaazwM3a5/QBDhsoNUJPXGl2g5CdqrfE0d7r+AUSHyw5RlNgbXqHlKGuu8jV4u/8CRYjMD1KV2Rxfm5vdGVzCgAAgTMH
            rjGfbj0pPRZBVJA5X4RjfWhqnsqd5kMBBtafVxHDaZpTUmWdt1jNMlNQCieMvitOKSlJw0uUFYM00t93d1du5r0a9W2v3hnxstxS
            vgf4G1/Hglolm3wqTGC3qN2eD4Iop7eAAAAXBo+tAQlqAAcLAQABIwMBAQVdABAAAAyAjgoBAsnRCgAA
            """),
    ]

    /// Stored and encrypted, file list too (`-mhe=on -psecret`), in three volumes.
    static let encrypted: [Data] = [
        volume("""
            N3q8ryccAAT4psBcYBAAAAAAAAA/AAAAAAAAAD5hjldJJxBAl1kS8JYROMlAckT72cE5Z7i06xpCpDnsRMNuxi7il/lZgSUAA1hi
            Psoa3VMmtynLEyIjX5T8cQrtOjkvhRvpCo7E5S8n/W1N9VrNs3zXxtXL5kO7UgJhDq9E2zSapEnNe7A622Yy6BY7KCg4bZYQb5E/
            ZsP4PzGVK+4QWhdhAZIjb6ZT9ljcfB/f5bDBvbz28HIAITdSmmKMOoeDQyeEtOfgg4AxCcLbVmpGtjy2SZwNN0u1rt5/kyIw65gf
            FLRxFYYg2PqJKIk2mFCcTKhjTOMA2ljJgZFgOmXs+AmNCBzKWr82ekeE0fzQNhyjw3Zis3SLvRsUO7CPt9gnUjGUKhfuHdanTGLl
            NB8Pr2lzQ0YjF2OoubffDK2vFUnPz7EeA/l8fUU+kaTSQ1yuLhe4S5e2uh06GiewZ7r06uFLD2u8gqSFaBQs8ejVReBvjqqAn31q
            IllNl4Vsz2sPKkijXgYu3WONdKtEZXmxfwY9n1csmvIuePZrY9UXn4gsd7ufnvD/f1ofHD9btd9QFNTPj3uyGlMxNpjRbOCjGQ90
            3GiaKQhx2HKOqn/cRUSXhQMf+UWiymH33UhCxraVMg3KKx9+1HFN5K1TbYHQqeu3R5FOohQkk2guYQlIlAtnS2ITsILUMYEDHWKr
            zHJ5l+y3CngL7QfOyQ7+V+7vnsCHn5E+/FvBtbKXwvarZBSdy3HAuCJC0GqIyZSIML6XbqludnLTPbxixZsaziNy2mTsgAteY8SV
            UT9C44wbvwQOESwg7Mn1ipUkQsQAk+TLSaxu7cMPvR6I2UM6eXMPgQkocDftm2r0fPI7DkB01/D27WOCFRBIkg36GOk9q6JHSb8L
            6zqz8sTI/BP/uTBLDy1IMNp4DrXHKgUAsywz9g7WM/+kpos2Znb4wXZ+X3WN2w6Y6DH5naQxNdg5c48W/l9Y6/ubt7qxFivbTOmC
            fZ3+/QNS+UTP0LGaOHLYwEjllMK8oILwgZT+p3dxQnGSleA+K6xPu8yw1Nr8eWv+8sfo4lIlwSq8qjNpQMUQW+BjBNHLXP9rbCCf
            PD/1QrKhxiORBGc5oA+yPyPJaDM4EI1qg2EqfKj7Nd4/EyqrDtSEaUHyFFk5PnisLS65lnGjeJox/WjIEcwqpMsV4/JaYscedbkl
            Tbc69MuUc8wd2CeiUR76zWOwJjN9SEmpkX4qKJFBY2/FGSiRqHLKWB+gChze0Pq54enkDIohtg9K/j0S5h7FC2pRdv/m9jVlYce7
            Py0T+y8rP/euWKBt244+TtR0FSphsp2Hvby95+E2v/EirBCFJnmVhRTE98wtHEbgjfBfVp9Ogo2KKBl81juNFbsOvvtyeDN4X8yO
            wRks/JywYRVBdmHH1+6nKInVSvBxezuKwf/LRYqnOv1VyjR4cVqPi4SVojfzEOxt4yprhF2PX/o4LoWf3NV4l3ZjXcnU/ttcYWYD
            Ffzrp/Rg0iWnGFog4kS+14G7uWKWs89aBt8T9Q5SzbC6bhVX7Mtf8HYA58ozNCEZOQ3n7exkwgRjR2Ix/W7ma/Zq+CznUvozq9jp
            VaCLi3A75dPOoNODX6N/UJLV+KPrJQqM2GPPVHOE3z3kV2zH+4B96gK0ZgFo3mVTCRpxwIHZNA+jYzNdBmpxr1q7uQVnl364IKLC
            coH11y843RTHkUlPjZRxk6Eag3ReAPLXZjFzo6XI+lG+d76XvLI2FqMvV2gGWQo/ecRged03TncuhYZHN0P4lDm52gHs6gZBePTk
            ePAvTj5jPysl+lGKgohkfoLqgTjw2fjAnePxQ7t0Oxpkn0cG5UQZQ0LL3wHraCzmDPwqdbQXaorZRf51D1NmEcAYEtTypnudgSf0
            zUn62uqODOiHEwdzOJQrtucrGo0wU5bGCRKlViy30PRGnxhBpv+umgDVu8tnMwAhcPpaf6G+oJ2lAwS6/6Q2c+/6WXt0hNEWQBC5
            """),
        volume("""
            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
            """),
        volume("""
            MgUVrOeHFFpt4mipf2dd/CIvEYIrNw1qVcddH9Rpv3ecKp8KCKm1IL8B8vtKiuIw0wBKdExItS8q+FAeoRoXWZjfrZETGfjL72Jd
            yDEfY8VSIA0Lwy43kB/2iJ09lmcFRZqaJqojlaghf640wOWzAh9hB9gOLbYDvGsPf5p2dyDnFTfTlXiF110fXm5ptSi9TSldBRun
            KVFnYj6zbBAA2rXHIvyzRVd6Y36p9S6BQuuxDkWveER316UdDsqpXoAplmEAQF4yl0UGhtzIXkA9emecWvVkpvT4Nk46EtGtnju9
            H28s0uPpPVaWpTMGjshiC2fBd0vZ604yIqun+m16hJcOaxIBvADshwy6Nw6/mmbUau2vk+bhz+evVQYw79Ka5VFV4mE8Xzs00+mt
            BFU+owUFn+cfOOH3/y437aiPIpdCbM9T7KiJNV0pqMLWaoPgYMC0grvgwGyg4arQxWF+jsjIiDkDpukHe3Hbs784Gz4Nz3Gis+Ws
            6QXEMRPRmg9Sjx9ITO+xiosSI/R0VpZQvq3eFjI69MWrz7rekXhnmRk+je4wq9k2TzZCMsm6YjD08pQEL5lATzd04OxxORPulYuj
            CECN70jGSN/3moy5L32Ii/aKVygKCgmJcN+ShJ5G9w5SWZt4PmUYEH0Z681GxFeBVFOtOAp6QzIrsO3r6m2+dq4DCyoDTkNoK3qd
            lm3PTpDOC6amfQkKDGTaWsalv6NJjCcTsO/E/KuELujqVBbo0DiPxyaevmsNyU1J/BfKFM4KA4/rTzoVden+t9xib6NpPMu5FSdL
            FCVSZhDrgpW57WqmGxGdD++lMFXiRskfzVq3yz7Nu9f9DXG0TZ1YnADtaFXF3p80Yd5InUsoU+D0TJ/ghtrS0Rk4ScPaoXXZasuf
            WgFsYnLdYnfYNy8EFKFcXP2y6iVGJWdL7jGUOuFbuGmGJapfLpvYjN9kssgLmdcegY8kOObyb1pC4D/Us/EJsflfz3Ahh9qr7uzp
            kOquh+N9ToDVhPIY06UYnRTZoLQf2Scwpk3vfYoc9OB5ivwagtZLA6PHcV3043SFKvU5ZiNTh1lw1RbQrz2HTtQZgTvFY4aGhar2
            JrhyedsuOMF5XLDEhX+zksBYBaIQfXe9ifpFMv6fTkzuAVW79LsxpEHuA7mWX0i1IAECShNJgIBf9OTgShRXLWXLfIJvoZP+lsNo
            Z1bXJMuXbGS56e9SbM01WaufyguPiKomllHcNPn3/XDqVGe9vf5gwhIfvxc+mXumEwbPOkv5urSKYlZAyOsEI2jMiAus7f4ryzPx
            12GhxWsDMNIbraakdVFJyX+jsJ9Ua6rWd2AJvGVPKCN57nW3WyVTeriN9tevgv+6qtnUMwV2LxmSepkLU86iwArbijP60udYE7uD
            2V0CQNYkt8E2JOXbYjHZFka/KU4AXCEoMQEECTGQMEVq62Qfo41vF4YxedtZINYEYv2w7pKNT1onQPJGJ11mKZhf+2aOsVdsHBgr
            txiaSd09zPlQQbuWTxK3hpxq3b5l1f/bmV5RzxGaC9Hp7hvXu5gzhCoJGhYFfiz2ECJ7wxA9f7ucsvxnY/cnJjP+gAi7takiNczE
            Lp4yygyG+4SYVGZseTPN9qzLd+Sfag3QFwaPwAEJgKAABwsBAAIkBvEHARJTD5tp3gwNc+WNp2QN2AcV3L8jAwEBBV0AEAAAAQAM
            gJ2AzgoBGAjcGQAA
            """),
    ]

    /// `lzmaPlain` compressed raw (properties apart, as 7z keeps them, with an end marker).
    static let lzmaProperties = Data([0x5D, 0x00, 0x00, 0x01, 0x00])
    static let lzmaData = volume("""
        ACcdSsarbUpeP1JV456VBmPniwJ+Hc+iYREmf56JuXz8Q4bYXgaWO0aOOa15J7R9uJxYs4kwz+///uHoAA==
        """)
    static let lzmaPlain: Data = {
        var bytes = [UInt8](String(repeating: "Nuvio streams Usenet. ", count: 100).utf8)
        for i in 0..<1000 { bytes.append(UInt8((i % 7) * 31)) }
        return Data(bytes)
    }()

    /// `lzmaMixedPlain` (random runs and text runs) compressed raw.
    static let lzmaMixedProperties = Data([0x5D, 0x00, 0x00, 0x10, 0x00])
    static let lzmaMixedData = volume("""
        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
        """)
    static let lzmaMixedPlain: Data = {
        var x: UInt32 = 7
        let text = [UInt8]("Nuvio streams Usenet. ".utf8)
        var bytes: [UInt8] = []
        for i in 0..<6000 {
            if (i / 300) % 2 == 0 {
                x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
                bytes.append(UInt8((x >> 16) & 0xFF))
            } else {
                bytes.append(text[i % text.count])
            }
        }
        return Data(bytes)
    }()

    /// The file both archives hold.
    static let content: Data = {
        var bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        for i in 4..<4007 { bytes.append(UInt8((i * 13 + i / 241) & 0xFF)) }
        return Data(bytes)
    }()

    private static func volume(_ base64: String) -> Data {
        Data(base64Encoded: base64.filter { !$0.isWhitespace })!
    }
}
