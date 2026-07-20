import Foundation
import AetherEngineSMB

// MARK: - smbtest: sequential throughput + random-seek correctness harness

@MainActor
private func smbTestRun(_ args: [String]) async -> Int32 {
    guard let rawURL = args.first(where: { !$0.hasPrefix("--") }) else {
        FileHandle.standardError.write(Data("usage: aetherctl smbtest <smb-url> [--reads N]\n".utf8))
        return 2
    }
    let randomReads = smbParseIntFlag(args, "--reads") ?? 64

    do {
        let u = try SMBURL.parse(rawURL)
        let started = ProcessInfo.processInfo.systemUptime
        print("connecting to \(u.server.absoluteString) share=\(u.share) path=\(u.path) user=\(u.user.isEmpty ? "(guest/anonymous)" : u.user)")
        let connection = try await SMBConnection.connect(
            server: u.server, share: u.share, path: u.path,
            user: u.user, password: u.password
        )
        let reader = SMBIOReader(source: connection)
        let total = reader.seek(offset: 0, whence: 65536) // AVSEEK_SIZE
        print("connected: \(u.path) size=\(total) bytes")

        let chunk = 1 << 20 // 1 MiB sequential read
        var buf = [UInt8](repeating: 0, count: chunk)
        var readBytes: Int64 = 0
        _ = reader.seek(offset: 0, whence: Int32(SEEK_SET))
        let seqStart = ProcessInfo.processInfo.systemUptime
        while true {
            let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(chunk)) }
            if n <= 0 { break }
            readBytes += Int64(n)
        }
        let seqElapsed = ProcessInfo.processInfo.systemUptime - seqStart
        let mibps = seqElapsed > 0 ? Double(readBytes) / 1_048_576.0 / seqElapsed : 0
        print(String(format: "sequential: %lld bytes in %.2fs = %.1f MiB/s", readBytes, seqElapsed, mibps))

        guard readBytes == total else {
            print("FAIL: sequential read \(readBytes) != size \(total)")
            return 1
        }

        // Random-seek correctness: two reads at each random offset must agree (deterministic content).
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<randomReads {
            let off = Int64.random(in: 0..<max(1, total - 16), using: &rng)
            let a = smbReadAt(reader, off, 16)
            let b = smbReadAt(reader, off, 16)
            if a != b {
                print("FAIL: random reads at \(off) disagree")
                return 1
            }
        }
        print("random-seek: \(randomReads) offsets consistent")

        reader.close()
        let wall = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "OK in %.2fs", wall))
        return 0
    } catch {
        FileHandle.standardError.write(Data("smbtest error: \(error)\n".utf8))
        return 1
    }
}

private func smbReadAt(_ reader: SMBIOReader, _ offset: Int64, _ length: Int) -> Data {
    _ = reader.seek(offset: offset, whence: Int32(SEEK_SET))
    var buf = [UInt8](repeating: 0, count: length)
    let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(length)) }
    return Data(buf.prefix(Int(max(n, 0))))
}

private func smbParseIntFlag(_ args: [String], _ flag: String) -> Int? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Int(args[i + 1])
}

func runSMBTest(_ args: [String]) -> Int32 {
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await smbTestRun(args)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
