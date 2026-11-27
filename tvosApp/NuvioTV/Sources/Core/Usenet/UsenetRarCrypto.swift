import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Password-protected RAR

/// How a RAR entry's bytes are encrypted, as its header says.
enum UsenetRarEncryption: Equatable, Sendable {
    /// RAR 5: AES-256-CBC; the key is PBKDF2-HMAC-SHA256 of the password over `2^count`
    /// rounds. `check` (12 bytes) tells a wrong password apart before anything is read.
    case rar5(count: Int, salt: Data, iv: Data, check: Data?)
    /// RAR 2.9–4.x: AES-128-CBC; key and IV come from the password and the salt (SHA-1,
    /// 2^18 rounds). Nothing tells a wrong password apart.
    case rar4(salt: Data)
}

/// The key a played file's stored bytes are decrypted with. The stored bytes are one CBC
/// chain over the whole file, across the volumes it is split over, padded to 16 bytes.
struct UsenetRarCipher: Equatable, Sendable {
    var key: Data
    var iv: Data
    /// The file's own size: the stored bytes run up to 15 bytes past it.
    var plainSize: Int64
    /// The archive confirmed the password (RAR 5's check value).
    var passwordChecked: Bool
}

/// How encrypted RAR headers are read, once the password opened them.
enum UsenetRarHeaderCipher: Equatable, Sendable {
    /// Each header: a 16-byte IV, then the header, AES-256-CBC, padded to 16 bytes.
    case rar5(key: Data)
    /// Each header: an 8-byte salt, then the header, AES-128-CBC, padded to 16 bytes.
    case rar4(password: String)
}

enum UsenetRarCrypto {
    /// RAR reads at most this many characters of a password.
    static let maxPasswordLength = 127
    /// RAR 5 allows up to 2^24 rounds; past 2^20 opening it would take seconds on an Apple TV.
    static let maxRar5Count = 20

    /// The key for an entry, checked against the archive's check value where there is one.
    static func cipher(for encryption: UsenetRarEncryption, password: String, plainSize: Int64) throws -> UsenetRarCipher {
        switch encryption {
        case let .rar5(count, salt, iv, check):
            guard count <= maxRar5Count, iv.count == 16 else { throw UsenetError.archiveEncrypted }
            let checked = check.map { isUsableCheck($0) } ?? false
            if checked, let check, !rar5PasswordMatches(check: check, password: password, salt: salt, count: count) {
                throw UsenetError.wrongPassword
            }
            guard let key = rar5Key(password: password, salt: salt, count: count) else { throw UsenetError.archiveEncrypted }
            return UsenetRarCipher(key: key, iv: iv, plainSize: plainSize, passwordChecked: checked)
        case .rar4(let salt):
            let derived = rar4Key(password: password, salt: salt)
            return UsenetRarCipher(key: derived.key, iv: derived.iv, plainSize: plainSize, passwordChecked: false)
        }
    }

    // MARK: RAR 5

    /// AES-256 key: PBKDF2-HMAC-SHA256 over `2^count` rounds.
    static func rar5Key(password: String, salt: Data, count: Int) -> Data? {
        cached("5k|\(count)", password: password, salt: salt) {
            pbkdf2(password: rar5Password(password), salt: salt, rounds: 1 << count)
        }
    }

    /// The archive's 12-byte check value: 8 bytes folded from PBKDF2 over 32 more rounds, then
    /// the first 4 bytes of their SHA-256.
    static func rar5PasswordMatches(check: Data, password: String, salt: Data, count: Int) -> Bool {
        guard count <= maxRar5Count, check.count >= 8,
              let value = cached("5c|\(count)", password: password, salt: salt, derive: {
                  pbkdf2(password: rar5Password(password), salt: salt, rounds: (1 << count) + 32).map { long in
                      var folded = [UInt8](repeating: 0, count: 8)
                      for (index, byte) in long.enumerated() { folded[index % 8] ^= byte }
                      return Data(folded)
                  }
              }) else { return false }
        return value == check.prefix(8)
    }

    /// A check value whose own checksum fails was damaged: RAR ignores it.
    static func isUsableCheck(_ check: Data) -> Bool {
        guard check.count == 12 else { return false }
        return Data(SHA256.hash(data: check.prefix(8))).prefix(4) == check.suffix(4)
    }

    /// UTF-8 of the password, cut to what RAR reads of it.
    static func rar5Password(_ password: String) -> Data {
        Data(String(decoding: Array(password.utf16.prefix(maxPasswordLength)), as: UTF16.self).utf8)
    }

    private static func pbkdf2(password: Data, salt: Data, rounds: Int) -> Data? {
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    // MARK: RAR 4

    /// AES-128 key and IV of RAR 2.9–4.x: 2^18 rounds of SHA-1 over the password (UTF-16LE),
    /// the salt and a counter. RAR's SHA-1 wrote its message schedule back into the input,
    /// which changes the result for passwords over 28 characters; that is reproduced here.
    static func rar4Key(password: String, salt: Data) -> (key: Data, iv: Data) {
        let both = cached("4", password: password, salt: salt) {
            let derived = rar4Derive(password: password, salt: salt)
            return derived.key + derived.iv
        } ?? Data(count: 32)
        return (Data(both.prefix(16)), Data(both.suffix(16)))
    }

    private static func rar4Derive(password: String, salt: Data) -> (key: Data, iv: Data) {
        var seed: [UInt8] = []
        for unit in password.utf16.prefix(maxPasswordLength) {
            seed.append(UInt8(unit & 0xFF))
            seed.append(UInt8(unit >> 8))
        }
        seed += salt
        let seedLength = seed.count
        var buffer = seed + [0, 0, 0]
        var iv = [UInt8](repeating: 0, count: 16)
        var hasher = Insecure.SHA1()
        var hashed = 0
        var counter = 0
        for round in 0..<16 {
            buffer[seedLength + 2] = UInt8((counter >> 16) & 0xFF)
            for step in 0..<0x4000 {
                let blockPosition = hashed & 63
                hashed += seedLength + 3
                buffer[seedLength] = UInt8(counter & 0xFF)
                buffer[seedLength + 1] = UInt8((counter >> 8) & 0xFF)
                counter += 1
                buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
                if seedLength > 64 {
                    var position = 64 - blockPosition
                    while position + 64 <= seedLength {
                        corrupt(&buffer, at: position)
                        position += 64
                    }
                }
                if step == 0 {
                    iv[round] = Array(hasher.finalize())[19]
                }
            }
        }
        let digest = Array(hasher.finalize())
        var key = [UInt8](repeating: 0, count: 16)
        for word in 0..<4 {
            for byte in 0..<4 { key[word * 4 + byte] = digest[word * 4 + 3 - byte] }
        }
        return (Data(key), Data(iv))
    }

    /// What RAR's SHA-1 left in a 64-byte block of its input: the block read as big-endian
    /// words, four rounds of the message schedule over them, written back little-endian.
    static func corrupt(_ buffer: inout [UInt8], at position: Int) {
        var w = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let p = position + i * 4
            w[i] = UInt32(buffer[p]) << 24 | UInt32(buffer[p + 1]) << 16 | UInt32(buffer[p + 2]) << 8 | UInt32(buffer[p + 3])
        }
        for _ in 0..<4 {
            for t in 0..<16 {
                let x = w[(t + 13) & 15] ^ w[(t + 8) & 15] ^ w[(t + 2) & 15] ^ w[t]
                w[t] = x << 1 | x >> 31
            }
        }
        for i in 0..<16 {
            let p = position + i * 4
            buffer[p] = UInt8(w[i] & 0xFF)
            buffer[p + 1] = UInt8((w[i] >> 8) & 0xFF)
            buffer[p + 2] = UInt8((w[i] >> 16) & 0xFF)
            buffer[p + 3] = UInt8(w[i] >> 24)
        }
    }

    // MARK: AES

    /// AES-CBC without padding; nil unless `data` is whole 16-byte blocks.
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard data.count % 16 == 0, iv.count == 16, key.count == 16 || key.count == 32 else { return nil }
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outputBytes.baseAddress, data.count, &moved
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == data.count else { return nil }
        return output
    }

    /// The plain bytes `[offset, offset + length)` out of `stored`, the stored bytes from
    /// `storedStart` (a multiple of 16, at most `offset`), of which whole blocks are used.
    /// `previous`: the 16 stored bytes before `storedStart`, which chain the decryption (the
    /// cipher's IV does at 0). Never past the file's own size.
    static func plain(_ stored: Data, storedStart: Int64, previous: Data?, cipher: UsenetRarCipher,
                      offset: Int64, length: Int) -> Data? {
        let blocks = stored.count / 16 * 16
        guard storedStart >= 0, storedStart % 16 == 0, offset >= storedStart, blocks > 0,
              let iv = storedStart == 0 ? cipher.iv : previous, iv.count == 16,
              let plain = decrypt(stored.prefix(blocks), key: cipher.key, iv: iv) else { return nil }
        let from = Int(offset - storedStart)
        let end = min(blocks, from + max(0, length), Int(clamping: cipher.plainSize - storedStart))
        guard from < end else { return Data() }
        return plain.subdata(in: from..<end)
    }

    /// Plain bytes of an encrypted file from `offset`: up to `maxLength`, ending at the first
    /// block boundary past `offset` that `read` stopped short of (an article or a volume ends
    /// there), never past the file. `read(offset, length, main)` gives stored bytes, up to an
    /// article or extent boundary; `main` is false for the 16 bytes before, which only chain
    /// the decryption (they don't move the read-ahead).
    static func plainRead(offset: Int64, maxLength: Int, cipher: UsenetRarCipher, storedSize: Int64,
                          read: @Sendable (Int64, Int, Bool) async throws -> Data) async throws -> Data {
        let plainSize = min(cipher.plainSize, storedSize)
        guard offset >= 0, offset < plainSize, maxLength > 0 else { return Data() }
        let start = offset / 16 * 16
        let wantedEnd = min(storedSize, (min(plainSize, offset + Int64(maxLength)) + 15) / 16 * 16)
        var stored = Data()
        var position = start
        while position < wantedEnd {
            let chunk = try await read(position, Int(wantedEnd - position), true)
            guard !chunk.isEmpty else { break }
            stored.append(chunk)
            position += Int64(chunk.count)
            if position > offset, position % 16 == 0 { break }
        }
        var previous = Data()
        if start > 0 {
            while previous.count < 16 {
                let chunk = try await read(start - 16 + Int64(previous.count), 16 - previous.count, false)
                guard !chunk.isEmpty else { break }
                previous.append(chunk)
            }
        }
        return plain(stored, storedStart: start, previous: previous, cipher: cipher, offset: offset, length: maxLength) ?? Data()
    }

    // MARK: Cache

    /// Derived keys by password and salt: every volume of a set repeats the same salt, and
    /// RAR 4 header encryption needs a key per header.
    private static let cache = KeyCache()

    private static func cached(_ kind: String, password: String, salt: Data, derive: () -> Data?) -> Data? {
        var input = Data(kind.utf8)
        input.append(0)
        input.append(salt)
        input.append(0)
        input.append(Data(password.utf8))
        let key = Data(SHA256.hash(data: input))
        if let value = cache.value(for: key) { return value }
        guard let value = derive() else { return nil }
        cache.store(value, for: key)
        return value
    }

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data: Data] = [:]
        private var order: [Data] = []

        func value(for key: Data) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: Data, for key: Data) {
            lock.lock()
            defer { lock.unlock() }
            if values.updateValue(value, forKey: key) == nil { order.append(key) }
            if order.count > 64 { values[order.removeFirst()] = nil }
        }
    }
}
