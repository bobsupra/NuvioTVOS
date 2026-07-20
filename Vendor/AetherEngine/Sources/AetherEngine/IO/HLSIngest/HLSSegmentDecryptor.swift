import Foundation
import CommonCrypto

/// AES-128-CBC/PKCS7 clear-key decryption for HLS EXT-X-KEY METHOD=AES-128 segments (Pluto/Samsung-TV+ style). Not a DRM system; standard HLS client behavior.
enum HLSSegmentDecryptor {

    /// Returns nil on malformed key/IV length or CommonCrypto failure; caller treats as terminal (host falls back to server-muxed route).
    static func decryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }

        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var plaintext = Data(count: outputCapacity)
        var decryptedCount = 0
        let status = plaintext.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, outputCapacity,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        plaintext.removeSubrange(decryptedCount..<plaintext.count)
        return plaintext
    }
}
