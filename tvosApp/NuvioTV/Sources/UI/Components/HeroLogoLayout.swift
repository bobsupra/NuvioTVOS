import CoreGraphics
import UIKit

/// Sizes Home's hero logos so logos from different sources look alike. A logo image
/// comes with its own transparent margins and shape, so each one fitted as is into the
/// same box came out a different size, at a different height and indent.
enum HeroLogoLayout {
    /// The area every logo gets, as a share of the largest box it may fill. A wide
    /// wordmark comes out shorter than a square logo, at the same visual weight. At half
    /// the box, a logo about twice as wide as it is tall just reaches the maximum height,
    /// so every logo from that shape outwards gets the same area.
    static let areaShare: CGFloat = 0.5
    /// Pixels at or below this alpha count as margin.
    static let marginAlpha: UInt8 = 8

    private static let visibleRects = NSCache<NSString, NSValue>()

    /// The size to draw a logo of `aspect`, its width over its height, at: `areaShare`
    /// of `maxWidth` × `maxHeight` for every logo, capped by both.
    static func size(aspect: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard aspect.isFinite, aspect > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: max(maxWidth, 0), height: max(maxHeight, 0))
        }
        var height = (areaShare * maxWidth * maxHeight / aspect).squareRoot()
        var width = height * aspect
        if width > maxWidth {
            width = maxWidth
            height = width / aspect
        }
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The rectangle of `image`'s visible pixels, top-left origin, or nil when there is no
    /// margin to cut: no alpha channel, nothing visible, or visible pixels on every edge.
    static func visibleBounds(of image: CGImage) -> CGRect? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return nil
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // The bitmap's first row is the image's top row.
        func rowIsVisible(_ y: Int) -> Bool {
            let start = y * bytesPerRow + 3
            var index = start
            while index < start + bytesPerRow {
                if pixels[index] > marginAlpha { return true }
                index += 4
            }
            return false
        }
        func columnIsVisible(_ x: Int, top: Int, bottom: Int) -> Bool {
            var y = top
            while y <= bottom {
                if pixels[y * bytesPerRow + x * 4 + 3] > marginAlpha { return true }
                y += 1
            }
            return false
        }
        guard let top = (0..<height).first(where: rowIsVisible),
              let bottom = (top..<height).reversed().first(where: rowIsVisible),
              let left = (0..<width).first(where: { columnIsVisible($0, top: top, bottom: bottom) }),
              let right = (left..<width).reversed().first(where: { columnIsVisible($0, top: top, bottom: bottom) })
        else { return nil }

        let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard bounds.width < CGFloat(width) || bounds.height < CGFloat(height) else { return nil }
        return bounds
    }

    /// The part of `image` worth showing, in points: its visible pixels, or the whole
    /// image when it has no margin to cut. An image drawn rotated or mirrored is shown
    /// whole, since its pixels don't run in display order.
    ///
    /// The hero draws the original image offset to this rectangle rather than a cropped
    /// copy, so each logo is drawn from the same image as before and no copy is kept.
    static func visibleRect(of image: UIImage) -> CGRect {
        let whole = CGRect(origin: .zero, size: image.size)
        guard image.imageOrientation == .up,
              let cgImage = image.cgImage,
              let bounds = visibleBounds(of: cgImage)
        else { return whole }
        let scale = image.scale
        return CGRect(
            x: bounds.minX / scale,
            y: bounds.minY / scale,
            width: bounds.width / scale,
            height: bounds.height / scale
        )
    }

    /// `visibleRect(of:)`, worked out off the main thread once per logo URL.
    static func visibleRect(of image: UIImage, for url: String) async -> CGRect {
        let key = url as NSString
        if let cached = visibleRects.object(forKey: key) { return cached.cgRectValue }
        let rect = await Task.detached(priority: .userInitiated) { visibleRect(of: image) }.value
        visibleRects.setObject(NSValue(cgRect: rect), forKey: key)
        return rect
    }
}
