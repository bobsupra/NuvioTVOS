import Foundation

/// One article of a posted file.
struct UsenetSegment: Sendable, Equatable {
    let messageID: String
    /// Encoded article size from the NZB (not the decoded size).
    let bytes: Int
    let number: Int
}

/// One posted file of an NZB.
struct UsenetFile: Sendable, Equatable {
    let subject: String
    let name: String
    let segments: [UsenetSegment]

    var encodedBytes: Int { segments.reduce(0) { $0 + $1.bytes } }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "mpg", "mpeg"]
    static let archiveExtensions: Set<String> = ["rar", "7z", "zip"]

    var isVideo: Bool { Self.videoExtensions.contains(fileExtension) }

    /// RAR volumes (.rar, .r00, .part01.rar), 7z and zip.
    var isArchive: Bool {
        if Self.archiveExtensions.contains(fileExtension) { return true }
        let ext = fileExtension
        return ext.count == 3 && ext.hasPrefix("r") && ext.dropFirst().allSatisfy(\.isNumber)
    }

    /// Repair data, checksums and info files that are never the thing to play.
    var isSidecar: Bool {
        ["par2", "sfv", "nfo", "nzb", "srr", "srs", "jpg", "png", "txt", "url"].contains(fileExtension)
    }
}

struct UsenetNZB: Sendable, Equatable {
    var title: String?
    var password: String?
    var files: [UsenetFile]

    /// Parses NZB XML; gzip-compressed NZBs (`.nzb.gz`) are inflated first.
    static func parse(_ data: Data) throws -> UsenetNZB {
        let xml = UsenetGzip.isGzip(data) ? try UsenetGzip.inflate(data) : data
        let parser = UsenetNZBParser()
        let xmlParser = XMLParser(data: xml)
        xmlParser.delegate = parser
        let ok = xmlParser.parse()
        guard !parser.files.isEmpty else {
            throw ok ? UsenetError.noPlayableFile : UsenetError.nzbUnreadable
        }
        return UsenetNZB(title: parser.title, password: parser.password, files: parser.files)
    }
}

private final class UsenetNZBParser: NSObject, XMLParserDelegate {
    var files: [UsenetFile] = []
    var title: String?
    var password: String?

    private var subject: String?
    private var segments: [UsenetSegment] = []
    private var segmentBytes = 0
    private var segmentNumber = 0
    private var metaType: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        switch elementName {
        case "file":
            subject = attributeDict["subject"]
            segments = []
        case "segment":
            segmentBytes = Int(attributeDict["bytes"] ?? "") ?? 0
            segmentNumber = Int(attributeDict["number"] ?? "") ?? (segments.count + 1)
        case "meta":
            metaType = attributeDict["type"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "segment":
            let id = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if !id.isEmpty {
                segments.append(UsenetSegment(messageID: id, bytes: segmentBytes, number: segmentNumber))
            }
        case "meta":
            if metaType == "title", !value.isEmpty { title = value }
            if metaType == "password", !value.isEmpty { password = value }
            metaType = nil
        case "file":
            let subject = self.subject ?? ""
            if !segments.isEmpty {
                // Duplicate segment numbers (reposts) keep the first copy.
                var seen = Set<Int>()
                let ordered = segments.sorted { $0.number < $1.number }.filter { seen.insert($0.number).inserted }
                files.append(UsenetFile(
                    subject: subject,
                    name: Self.filename(fromSubject: subject, fallback: "file\(files.count + 1)"),
                    segments: ordered
                ))
            }
            self.subject = nil
        default:
            break
        }
        text = ""
    }

    /// The name inside the first pair of double quotes (the Usenet convention),
    /// else a token that looks like a filename, else the fallback.
    static func filename(fromSubject subject: String, fallback: String) -> String {
        if let open = subject.firstIndex(of: "\""),
           let close = subject[subject.index(after: open)...].firstIndex(of: "\"") {
            let name = String(subject[subject.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        for token in subject.split(whereSeparator: { $0 == " " || $0 == "\"" }) where token.contains(".") && !token.hasPrefix("(") {
            return String(token)
        }
        return fallback
    }
}

/// Minimal gzip reader: strips the RFC 1952 header/trailer and inflates the raw
/// DEFLATE body with the system decoder.
enum UsenetGzip {
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func inflate(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw UsenetError.nzbUnreadable
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard index + 2 <= bytes.count else { throw UsenetError.nzbUnreadable }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 {                       // FNAME
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {                       // FCOMMENT
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }          // FHCRC
        guard index < bytes.count - 8 else { throw UsenetError.nzbUnreadable }
        let deflate = Data(bytes[index..<(bytes.count - 8)])
        do {
            return try (deflate as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw UsenetError.nzbUnreadable
        }
    }
}
