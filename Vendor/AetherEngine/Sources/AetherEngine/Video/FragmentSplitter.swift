import Foundation

/// Streaming ISOBMFF box parser that splits mp4 muxer output into header (ftyp+moov, fired once via `onHeaderComplete`) and fragment (moof+mdat, streamed via `onFragmentBytes`) portions. Handles largesize (size==1) and discards mfra/unknown boxes.
final class FragmentSplitter {

    /// Fires once when moov closes; carries the complete ftyp+moov bytes (init.mp4 content).
    let onHeaderComplete: (Data) -> Void

    /// Called for every fragment-box byte (moof, mdat, styp, sidx), including box headers.
    let onFragmentBytes: (UnsafePointer<UInt8>, Int) -> Void

    private enum Phase {
        case awaitingBoxHeader
        case awaitingLargeSize(boxType: String)
        case insideHeaderBox(boxType: String, bytesRemaining: Int)
        case insideFragmentBox(boxType: String, bytesRemaining: Int)
        case insideDiscardBox(boxType: String, bytesRemaining: Int)
    }
    private var phase: Phase = .awaitingBoxHeader

    /// Accumulates the 8-byte box header (size+type) across split feed() calls.
    private var pendingHeaderBytes: [UInt8] = []
    private var headerBuffer = Data()

    init(onHeaderComplete: @escaping (Data) -> Void,
         onFragmentBytes: @escaping (UnsafePointer<UInt8>, Int) -> Void) {
        self.onHeaderComplete = onHeaderComplete
        self.onFragmentBytes = onFragmentBytes
        self.pendingHeaderBytes.reserveCapacity(16)
    }

    /// Feed `count` bytes of muxer output; boxes may span multiple calls.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        var offset = 0
        while offset < count {
            switch phase {
            case .awaitingBoxHeader:
                offset = consumeBoxHeader(bytes, offset: offset, count: count)

            case .awaitingLargeSize(let boxType):
                offset = consumeLargeSize(bytes, offset: offset, count: count, boxType: boxType)

            case .insideHeaderBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                headerBuffer.append(bytes.advanced(by: offset), count: take)
                let newRemaining = remaining - take
                offset += take
                if newRemaining == 0 {
                    if boxType == "moov" {
                        onHeaderComplete(headerBuffer)
                        headerBuffer = Data()
                    }
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideHeaderBox(boxType: boxType, bytesRemaining: newRemaining)
                }

            case .insideFragmentBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                onFragmentBytes(bytes.advanced(by: offset), take)
                let newRemaining = remaining - take
                offset += take
                if newRemaining == 0 {
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideFragmentBox(boxType: boxType, bytesRemaining: newRemaining)
                }

            case .insideDiscardBox(let boxType, let remaining):
                let take = min(remaining, count - offset)
                offset += take
                let newRemaining = remaining - take
                if newRemaining == 0 {
                    phase = .awaitingBoxHeader
                } else {
                    phase = .insideDiscardBox(boxType: boxType, bytesRemaining: newRemaining)
                }
            }
        }
    }

    // MARK: - Box header parsing

    private func consumeBoxHeader(_ bytes: UnsafePointer<UInt8>, offset: Int, count: Int) -> Int {
        var offset = offset
        let needed = 8 - pendingHeaderBytes.count
        let available = count - offset
        let take = min(needed, available)
        for i in 0..<take {
            pendingHeaderBytes.append(bytes[offset + i])
        }
        offset += take
        guard pendingHeaderBytes.count == 8 else { return offset }

        let size = UInt32(pendingHeaderBytes[0]) << 24
            | UInt32(pendingHeaderBytes[1]) << 16
            | UInt32(pendingHeaderBytes[2]) << 8
            | UInt32(pendingHeaderBytes[3])
        let typeBytes = Array(pendingHeaderBytes[4..<8])
        let boxType = String(bytes: typeBytes, encoding: .ascii) ?? "????"
        let headerBytes = pendingHeaderBytes
        pendingHeaderBytes.removeAll(keepingCapacity: true)

        if size == 1 {
            // 64-bit largesize follows in the next 8 bytes.
            pendingHeaderBytes = headerBytes
            phase = .awaitingLargeSize(boxType: boxType)
            return offset
        }
        if size == 0 {
            // "To end of file": discard.
            startBox(type: boxType, headerBytes: headerBytes, bodySize: Int.max)
            return offset
        }
        let bodySize = max(0, Int(size) - 8)
        startBox(type: boxType, headerBytes: headerBytes, bodySize: bodySize)
        return offset
    }

    private func consumeLargeSize(_ bytes: UnsafePointer<UInt8>, offset: Int, count: Int, boxType: String) -> Int {
        var offset = offset
        let needed = 16 - pendingHeaderBytes.count  // pendingHeaderBytes already holds the 8-byte initial header
        let available = count - offset
        let take = min(needed, available)
        for i in 0..<take {
            pendingHeaderBytes.append(bytes[offset + i])
        }
        offset += take
        guard pendingHeaderBytes.count == 16 else { return offset }

        var largesize: UInt64 = 0
        for i in 8..<16 {
            largesize = (largesize << 8) | UInt64(pendingHeaderBytes[i])
        }
        let headerBytes = pendingHeaderBytes
        pendingHeaderBytes.removeAll(keepingCapacity: true)

        let bodySize = max(0, Int(clamping: largesize) - 16)  // Int(clamping:) guards against corrupt >Int.max sizes
        startBox(type: boxType, headerBytes: headerBytes, bodySize: bodySize)
        return offset
    }

    private func startBox(type: String, headerBytes: [UInt8], bodySize: Int) {
        switch type {
        case "ftyp", "moov":
            headerBuffer.append(contentsOf: headerBytes)
            phase = .insideHeaderBox(boxType: type, bytesRemaining: bodySize)

        case "moof", "mdat", "styp", "sidx":
            headerBytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                onFragmentBytes(base, headerBytes.count)
            }
            phase = .insideFragmentBox(boxType: type, bytesRemaining: bodySize)

        default:
            // mfra, free, skip, udta, unknown: discard.
            phase = .insideDiscardBox(boxType: type, bytesRemaining: bodySize)
        }
    }
}
