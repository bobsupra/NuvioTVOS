import Foundation
@testable import AetherEngine

/// Minimal ISO9660 image builder for tests. Sector 16=PVD, 17=root, 18=VIDEO_TS, 19+=file data (one sector each, MPEG-PS pattern bytes).
enum ISO9660Fixture {
    static let sectorSize = 2048

    struct FileSpec {
        let name: String   // e.g. "VTS_01_1.VOB"
        let length: Int    // declared byte length
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    static func be32(_ v: Int) -> [UInt8] { Array(le32(v).reversed()) }
    static func both16(_ v: Int) -> [UInt8] { le16(v) + be16(v) }
    static func both32(_ v: Int) -> [UInt8] { le32(v) + be32(v) }

    /// One ISO9660 directory record. `name` is the raw identifier bytes
    /// (files carry a ";1" version suffix; "." and ".." are 0x00 / 0x01).
    static func dirRecord(name: [UInt8], isDir: Bool, lba: Int, length: Int) -> [UInt8] {
        var r = [UInt8]()
        r.append(0)                 // [0] record length (filled at end)
        r.append(0)                 // [1] extended attr length
        r += both32(lba)            // [2..9] extent LBA
        r += both32(length)         // [10..17] data length
        r += [UInt8](repeating: 0, count: 7)  // [18..24] recording date
        r.append(isDir ? 0x02 : 0x00)         // [25] file flags
        r.append(0)                 // [26] file unit size
        r.append(0)                 // [27] interleave gap
        r += both16(1)              // [28..31] volume sequence number
        r.append(UInt8(name.count)) // [32] length of file identifier
        r += name                   // [33..] file identifier
        if r.count % 2 != 0 { r.append(0) }   // pad to even length
        r[0] = UInt8(r.count)
        return r
    }

    /// Build a complete fixture image. Returns the bytes; wrap in DataIOReader.
    static func make(files: [FileSpec]) -> Data {
        // Reserve fixed sectors; declares real `length` in the record but fills only 1 sector per file (all tests read).
        let rootLBA = 17, videoTsLBA = 18
        var fileLBA = 19
        var fileExtents: [(spec: FileSpec, lba: Int)] = []
        for f in files { fileExtents.append((f, fileLBA)); fileLBA += 1 }

        // --- VIDEO_TS directory extent ---
        var videoTs = [UInt8]()
        videoTs += dirRecord(name: [0x00], isDir: true, lba: videoTsLBA, length: sectorSize) // .
        videoTs += dirRecord(name: [0x01], isDir: true, lba: rootLBA, length: sectorSize)     // ..
        for fe in fileExtents {
            let id = Array((fe.spec.name + ";1").utf8)
            videoTs += dirRecord(name: id, isDir: false, lba: fe.lba, length: fe.spec.length)
        }

        // --- root directory extent ---
        var root = [UInt8]()
        root += dirRecord(name: [0x00], isDir: true, lba: rootLBA, length: sectorSize)         // .
        root += dirRecord(name: [0x01], isDir: true, lba: rootLBA, length: sectorSize)         // ..
        root += dirRecord(name: Array("VIDEO_TS".utf8), isDir: true, lba: videoTsLBA, length: sectorSize)

        // --- PVD (sector 16) ---
        var pvd = [UInt8](repeating: 0, count: sectorSize)
        pvd[0] = 1                                   // descriptor type = primary
        for (i, b) in Array("CD001".utf8).enumerated() { pvd[1 + i] = b }
        pvd[6] = 1                                   // version
        let bs = both16(sectorSize)                  // logical block size @ 128
        for (i, b) in bs.enumerated() { pvd[128 + i] = b }
        let rootRec = dirRecord(name: [0x00], isDir: true, lba: rootLBA, length: sectorSize)
        for (i, b) in rootRec.enumerated() { pvd[156 + i] = b }  // root dir record @ 156

        // --- assemble image ---
        var image = [UInt8](repeating: 0, count: fileLBA * sectorSize)
        func put(_ bytes: [UInt8], atSector s: Int) {
            for (i, b) in bytes.enumerated() where i < sectorSize { image[s * sectorSize + i] = b }
        }
        put(pvd, atSector: 16)
        put(root, atSector: rootLBA)
        put(videoTs, atSector: videoTsLBA)
        for fe in fileExtents {
            // MPEG-PS pack-start code + file name bytes, so concat/disc tests can assert byte identity at extent boundaries.
            var payload: [UInt8] = [0x00, 0x00, 0x01, 0xBA]
            payload += Array(fe.spec.name.utf8)
            put(payload, atSector: fe.lba)
        }
        return Data(image)
    }
}
