//
//  AnimatedRemoteGIFView.swift
//  NuvioTV
//
//  Animated GIF overlay for collection folder focus art.
//  Matches Android TV / Compose architecture:
//  - Decodes GIF frames via ImageIO with frame duration extraction
//  - Normalizes frame delays via GCD expansion into uniform tick intervals
//  - Uses native UIImage.animatedImage / UIImageView hardware-accelerated playback
//    eliminating CADisplayLink main-thread timer stalls
//  - Memory-safe thumbnail scaling and LRU NSCache storage
//

import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
/// Plays a remote animated image (GIF) when `isActive` is true.
struct AnimatedRemoteGIFView: View {
    let urlString: String
    var isActive: Bool = true
    var contentMode: UIView.ContentMode = .scaleAspectFill

    @State private var decoded: DecodedAnimatedImage?
    @State private var loadFailed = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let decoded {
                NativeAnimatedGIFRepresentable(
                    decoded: decoded,
                    isPlaying: isActive,
                    contentMode: contentMode
                )
            }
        }
        .opacity(isActive && decoded != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isActive && decoded != nil)
        .onAppear { ensureLoaded() }
        .onChange(of: urlString) { _, _ in
            decoded = nil
            loadFailed = false
            ensureLoaded()
        }
        .onChange(of: isActive) { _, active in
            if active { ensureLoaded() }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func ensureLoaded() {
        guard !loadFailed else { return }
        if decoded != nil { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            loadFailed = true
            return
        }
        if let cached = AnimatedGIFCache.shared.image(for: url) {
            decoded = cached
            return
        }
        loadTask?.cancel()
        loadTask = Task {
            let image = await AnimatedGIFCache.shared.load(url: url)
            guard !Task.isCancelled else { return }
            if let image {
                decoded = image
            } else {
                loadFailed = true
            }
        }
    }
}

// MARK: - Decoded Multi-Frame Image

final class DecodedAnimatedImage: @unchecked Sendable {
    let animatedImage: UIImage
    let firstFrame: UIImage
    let frameCount: Int
    let duration: TimeInterval
    let isAnimated: Bool
    let totalByteCost: Int

    init(
        animatedImage: UIImage,
        firstFrame: UIImage,
        frameCount: Int,
        duration: TimeInterval,
        totalByteCost: Int
    ) {
        self.animatedImage = animatedImage
        self.firstFrame = firstFrame
        self.frameCount = frameCount
        self.duration = duration
        self.isAnimated = frameCount > 1
        self.totalByteCost = totalByteCost
    }

    convenience init(singleFrame: UIImage) {
        let cost = singleFrame.decodedByteCost
        self.init(
            animatedImage: singleFrame,
            firstFrame: singleFrame,
            frameCount: 1,
            duration: 0.1,
            totalByteCost: max(1024, cost)
        )
    }
}

// MARK: - Native Hardware-Accelerated View

private final class NativeAnimatedGIFUIView: UIImageView {
    private var currentDecoded: DecodedAnimatedImage?
    private var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func setDecoded(_ decoded: DecodedAnimatedImage?, playing: Bool, contentMode: UIView.ContentMode) {
        self.contentMode = contentMode
        let imageChanged = self.currentDecoded !== decoded
        self.currentDecoded = decoded
        self.isPlaying = playing

        if imageChanged {
            if let decoded {
                self.image = decoded.animatedImage
            } else {
                self.image = nil
            }
        }

        updatePlayback()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    private func updatePlayback() {
        guard let decoded = currentDecoded, decoded.isAnimated, isPlaying, window != nil else {
            if isAnimating {
                stopAnimating()
            }
            return
        }

        if !isAnimating {
            startAnimating()
        }
    }
}

private struct NativeAnimatedGIFRepresentable: UIViewRepresentable {
    let decoded: DecodedAnimatedImage
    var isPlaying: Bool
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> NativeAnimatedGIFUIView {
        let view = NativeAnimatedGIFUIView()
        view.setDecoded(decoded, playing: isPlaying, contentMode: contentMode)
        return view
    }

    func updateUIView(_ uiView: NativeAnimatedGIFUIView, context: Context) {
        uiView.setDecoded(decoded, playing: isPlaying, contentMode: contentMode)
    }

    static func dismantleUIView(_ uiView: NativeAnimatedGIFUIView, coordinator: ()) {
        uiView.setDecoded(nil, playing: false, contentMode: .scaleAspectFill)
    }
}

// MARK: - Cache & Decode

final class AnimatedGIFCache: @unchecked Sendable {
    static let shared = AnimatedGIFCache()
    private static let tracker = NSCacheMemoryTracker(maxCost: 32 * 1024 * 1024)

    static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [String: Task<DecodedAnimatedImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 16
        cache.totalCostLimit = Self.tracker.maxCost
        cache.delegate = Self.tracker
    }

    func image(for url: URL) -> DecodedAnimatedImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func load(url: URL) async -> DecodedAnimatedImage? {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let (task, ownsTask) = lock.withLock {
            if let existing = inFlight[key] {
                return (existing, false)
            }
            let task = Task.detached(priority: .utility) { () -> DecodedAnimatedImage? in
                await Self.fetchAndDecode(url: url)
            }
            inFlight[key] = task
            return (task, true)
        }

        let image = await task.value

        if ownsTask {
            lock.withLock {
                inFlight[key] = nil
            }
        }

        if let image {
            let cost = image.totalByteCost
            if cost <= Self.tracker.maxCost {
                cache.setObject(image, forKey: key as NSString, cost: cost)
                Self.tracker.recordInsertion(cost: cost)
            }
        }
        return image
    }

    private static func fetchAndDecode(url: URL) async -> DecodedAnimatedImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return makeDecodedImage(from: data)
        } catch {
            return nil
        }
    }

    static func makeDecodedImage(from data: Data) -> DecodedAnimatedImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(singleFrame: still)
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(singleFrame: still)
        }

        if count == 1 {
            guard let cgImage = createFrameImage(source: source, index: 0, maxPixelSize: 360) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                guard let still = UIImage(data: data) else { return nil }
                return DecodedAnimatedImage(singleFrame: still)
            }
            return DecodedAnimatedImage(singleFrame: UIImage(cgImage: cgImage))
        }

        // Downsample frames and cap source frames to prevent memory explosion on Apple TV
        let maxSourceFrames = 30
        let stride = max(1, Int(ceil(Double(count) / Double(maxSourceFrames))))
        let maxPixelSize = 320

        var sampledFrames: [(image: UIImage, delayCentiseconds: Int)] = []
        sampledFrames.reserveCapacity(min(count, maxSourceFrames))

        var index = 0
        while index < count {
            var accumulatedCentiseconds = 0
            let spanEnd = min(index + stride, count)
            for subIndex in index..<spanEnd {
                accumulatedCentiseconds += frameDelay(source: source, index: subIndex)
            }

            if let cgImage = createFrameImage(source: source, index: index, maxPixelSize: maxPixelSize) {
                sampledFrames.append((UIImage(cgImage: cgImage), max(1, accumulatedCentiseconds)))
            }
            index += stride
        }

        guard !sampledFrames.isEmpty else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(singleFrame: still)
        }

        guard sampledFrames.count > 1 else {
            return DecodedAnimatedImage(singleFrame: sampledFrames[0].image)
        }

        guard let expanded = expandFrames(frames: sampledFrames, maxExpandedCount: 90) else {
            return DecodedAnimatedImage(singleFrame: sampledFrames[0].image)
        }

        guard let animatedImage = UIImage.animatedImage(with: expanded.images, duration: expanded.duration) else {
            return DecodedAnimatedImage(singleFrame: sampledFrames[0].image)
        }

        // Distinct frame buffer cost (excluding pointer repetitions from GCD expansion)
        let totalByteCost = sampledFrames.reduce(0) { $0 + $1.image.decodedByteCost }
        return DecodedAnimatedImage(
            animatedImage: animatedImage,
            firstFrame: expanded.images[0],
            frameCount: expanded.images.count,
            duration: expanded.duration,
            totalByteCost: max(1024, totalByteCost)
        )
    }

    private static func createFrameImage(
        source: CGImageSource,
        index: Int,
        maxPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
            if thumb.width <= maxPixelSize && thumb.height <= maxPixelSize {
                return thumb
            }
            return downscaleCGImage(thumb, maxPixelSize: maxPixelSize)
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        return downscaleCGImage(raw, maxPixelSize: maxPixelSize)
    }

    private static func downscaleCGImage(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > maxPixelSize || height > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(max(width, height))
        let targetWidth = max(1, Int(round(Double(width) * scale)))
        let targetHeight = max(1, Int(round(Double(height) * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    /// Frame delay in centiseconds (1/100th of a second).
    static func frameDelay(source: CGImageSource, index: Int) -> Int {
        let defaultCentiseconds = 10
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return defaultCentiseconds
        }

        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]

        let unclamped = numberValue(gif?[kCGImagePropertyGIFUnclampedDelayTime])
            ?? numberValue(png?[kCGImagePropertyAPNGUnclampedDelayTime])
        let clamped = numberValue(gif?[kCGImagePropertyGIFDelayTime])
            ?? numberValue(png?[kCGImagePropertyAPNGDelayTime])

        let delaySeconds = unclamped ?? clamped ?? 0.10
        let centiseconds = Int(round(delaySeconds * 100))
        // Browser / GIF89a standard: delays < 20ms (2 centiseconds) are treated as 100ms (10 centiseconds)
        if centiseconds < 2 {
            return 10
        }
        return max(1, centiseconds)
    }

    private static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        default:
            return nil
        }
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            let temp = x % y
            x = y
            y = temp
        }
        return max(1, x)
    }

    struct ExpandedFrames {
        let images: [UIImage]
        let duration: TimeInterval
    }

    static func expandFrames(
        frames: [(image: UIImage, delayCentiseconds: Int)],
        maxExpandedCount: Int = 120
    ) -> ExpandedFrames? {
        guard !frames.isEmpty else { return nil }
        if frames.count == 1 {
            return ExpandedFrames(
                images: [frames[0].image],
                duration: max(0.01, Double(frames[0].delayCentiseconds) / 100.0)
            )
        }

        let delays = frames.map { max(1, $0.delayCentiseconds) }
        let tickCentiseconds = delays.reduce(delays[0], greatestCommonDivisor)
        let totalCentiseconds = delays.reduce(0, +)
        let estimatedExpandedCount = delays.reduce(0) { $0 + ($1 / tickCentiseconds) }

        if estimatedExpandedCount > maxExpandedCount {
            let images = frames.map { $0.image }
            let duration = Double(totalCentiseconds) / 100.0
            return ExpandedFrames(images: images, duration: max(0.1, duration))
        }

        var expandedImages: [UIImage] = []
        expandedImages.reserveCapacity(estimatedExpandedCount)
        for frame in frames {
            let repeatCount = max(1, frame.delayCentiseconds / tickCentiseconds)
            for _ in 0..<repeatCount {
                expandedImages.append(frame.image)
            }
        }

        let duration = Double(expandedImages.count * tickCentiseconds) / 100.0
        return ExpandedFrames(images: expandedImages, duration: max(0.1, duration))
    }
}
#endif
