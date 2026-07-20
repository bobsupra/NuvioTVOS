import Foundation
import CoreMedia

/// Render a FourCC ('hvc1', 'dvh1', 'mp4a', ...) as printable ASCII; non-printable bytes become '.'.
/// Shared by native host failure dumps and display-criteria logging (was two identical private copies).
func fourccString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ]
    let chars = bytes.map { (b: UInt8) -> Character in
        (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
    }
    return String(chars)
}
