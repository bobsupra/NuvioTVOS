import CoreGraphics
import CoreImage
import SwiftUI

/// A link as a QR code, for a phone to open: the Apple TV can't open web pages.
struct SettingsQRCodeCard: View {
    let title: String
    let link: String

    var body: some View {
        VStack(spacing: 10) {
            if let image = SettingsQRCode.image(for: link) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 150, height: 150)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text(SettingsQRCode.displayText(for: link))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
        }
    }
}

enum SettingsQRCode {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    /// The QR code of `link` (error correction M), one module per pixel scaled up crisply by
    /// the view; made once per link.
    static func image(for link: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[link] { return cached }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        cache[link] = image
        return image
    }

    /// The link as people type it: no scheme, no trailing slash.
    static func displayText(for link: String) -> String {
        var text = link
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
