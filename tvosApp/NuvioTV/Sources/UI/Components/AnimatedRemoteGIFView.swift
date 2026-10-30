//
//  AnimatedRemoteGIFView.swift
//  NuvioTV
//
//  Hardware-accelerated animated GIF overlay for collection folder focus art.
//  Matches and exceeds Android TV / Compose architecture:
//  - Decodes GIF frames via ImageIO with precise per-frame duration extraction
//  - Preserves exact millisecond per-frame timings with normalized keyTimes
//    eliminating GCD collapse and frame pacing distortion
//  - Uses native CAKeyframeAnimation on CALayer for hardware GPU composition
//  - Higher frame ceiling (up to 120 frames at full 30-60 fps) to eliminate stutter
//  - Inactive / non-focused cards suspend animations immediately and show the first
//    frame as a static layer, eliminating background compositor thrash
//  - Dedicated disk-backed URLCache for downloaded GIF assets
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
        .onAppear {
            loadFailed = false
            ensureLoaded()
        }
        .onChange(of: urlString) { _, _ in
            decoded = nil
            loadFailed = false
            ensureLoaded()
        }
        .onChange(of: isActive) { _, active in
            if active {
                // Retry a transient failure when the same mounted card regains focus.
                loadFailed = false
                ensureLoaded()
            }
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
    let cgFrames: [CGImage]
    let keyTimes: [NSNumber]

    init(
        animatedImage: UIImage,
        firstFrame: UIImage,
        frameCount: Int,
        duration: TimeInterval,
        totalByteCost: Int,
        cgFrames: [CGImage] = [],
        keyTimes: [NSNumber] = []
    ) {
        self.animatedImage = animatedImage
        self.firstFrame = firstFrame
        self.frameCount = frameCount
        self.duration = duration
        self.isAnimated = frameCount > 1
        self.totalByteCost = totalByteCost
        self.cgFrames = cgFrames.isEmpty ? (firstFrame.cgImage.map { [$0] } ?? []) : cgFrames
        self.keyTimes = keyTimes.isEmpty ? [0.0] : keyTimes
    }

    convenience init(singleFrame: UIImage) {
        let cost = singleFrame.decodedByteCost
        self.init(
            animatedImage: singleFrame,
            firstFrame: singleFrame,
            frameCount: 1,
            duration: 0.1,
            totalByteCost: max(1024, cost),
            cgFrames: singleFrame.cgImage.map { [$0] } ?? [],
            keyTimes: [0.0]
        )
    }

    func makeKeyframeAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = cgFrames
        animation.keyTimes = keyTimes
        animation.duration = max(0.01, duration)
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

// MARK: - Native Hardware-Accelerated View

private final class NativeAnimatedGIFUIView: UIView {
    private var currentDecoded: DecodedAnimatedImage?
    private var isPlaying = false
    private var isAnimatingLayer = false

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
        layer.masksToBounds = true
        updateGravity(for: .scaleAspectFill)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func setDecoded(_ decoded: DecodedAnimatedImage?, playing: Bool, contentMode: UIView.ContentMode) {
        self.contentMode = contentMode
        updateGravity(for: contentMode)

        let imageChanged = self.currentDecoded !== decoded
        let playStateChanged = self.isPlaying != playing
        self.currentDecoded = decoded
        self.isPlaying = playing

        if imageChanged || playStateChanged {
            updatePlayback()
        }
    }

    private func updateGravity(for mode: UIView.ContentMode) {
        switch mode {
        case .scaleAspectFill:
            layer.contentsGravity = .resizeAspectFill
        case .scaleAspectFit:
            layer.contentsGravity = .resizeAspect
        case .scaleToFill:
            layer.contentsGravity = .resize
        case .center:
            layer.contentsGravity = .center
        case .top:
            layer.contentsGravity = .top
        case .bottom:
            layer.contentsGravity = .bottom
        case .left:
            layer.contentsGravity = .left
        case .right:
            layer.contentsGravity = .right
        default:
            layer.contentsGravity = .resizeAspectFill
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    private func updatePlayback() {
        guard let decoded = currentDecoded, decoded.isAnimated, isPlaying, window != nil else {
            if isAnimatingLayer {
                layer.removeAnimation(forKey: "gifAnimation")
                isAnimatingLayer = false
            }
            layer.contents = currentDecoded?.firstFrame.cgImage
            return
        }

        layer.contents = decoded.firstFrame.cgImage
        layer.removeAnimation(forKey: "gifAnimation")
        layer.add(decoded.makeKeyframeAnimation(), forKey: "gifAnimation")
        isAnimatingLayer = true
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
    private static let tracker = NSCacheMemoryTracker(maxCost: 64 * 1024 * 1024)

    static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [String: Task<DecodedAnimatedImage?, Never>] = [:]
    private let lock = NSLock()

    private static let gifURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 80 * 1024 * 1024,
            diskPath: "nuvio_gif_cache"
        )
        return URLSession(configuration: config)
    }()

    private init() {
        cache.countLimit = 16
        cache.totalCostLimit = Self.tracker.maxCost
        cache.delegate = Self.tracker
    }

    func image(for url: URL) -> DecodedAnimatedImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func preload(url: URL) {
        if image(for: url) != nil { return }
        Task.detached(priority: .utility) {
            _ = await self.load(url: url)
        }
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
            let task = Task.detached(priority: .userInitiated) { () -> DecodedAnimatedImage? in
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
            let (data, response) = try await gifURLSession.data(from: url)
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
            guard let cgImage = createFrameImage(source: source, index: 0, maxPixelSize: 420) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                guard let still = UIImage(data: data) else { return nil }
                return DecodedAnimatedImage(singleFrame: still)
            }
            return DecodedAnimatedImage(singleFrame: UIImage(cgImage: cgImage))
        }

        // Higher frame ceiling (up to 120 frames) so 30-60 fps collection GIFs are never decimated down to 7-15 fps.
        let maxSourceFrames = 120
        let stride = max(1, Int(ceil(Double(count) / Double(maxSourceFrames))))
        let maxPixelSize: Int = count > 60 ? 380 : 440

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

        // Exact per-frame timings for CAKeyframeAnimation
        let totalCentiseconds = sampledFrames.reduce(0) { $0 + $1.delayCentiseconds }
        let totalDuration = max(0.01, Double(totalCentiseconds) / 100.0)

        var cumulativeCentiseconds = 0
        var keyTimes: [NSNumber] = []
        keyTimes.reserveCapacity(sampledFrames.count)
        var cgFrames: [CGImage] = []
        cgFrames.reserveCapacity(sampledFrames.count)

        for frame in sampledFrames {
            if let cg = frame.image.cgImage {
                cgFrames.append(cg)
                let progress = Double(cumulativeCentiseconds) / Double(max(1, totalCentiseconds))
                keyTimes.append(NSNumber(value: progress))
            }
            cumulativeCentiseconds += frame.delayCentiseconds
        }

        guard !cgFrames.isEmpty else {
            return DecodedAnimatedImage(singleFrame: sampledFrames[0].image)
        }

        // Fallback UIImage.animatedImage for any consumers reading animatedImage property
        let expanded = expandFrames(frames: sampledFrames, maxExpandedCount: 120)
        let animatedImage = expanded.flatMap { UIImage.animatedImage(with: $0.images, duration: $0.duration) }
            ?? sampledFrames[0].image

        // Distinct frame buffer cost
        let totalByteCost = sampledFrames.reduce(0) { $0 + $1.image.decodedByteCost }
        return DecodedAnimatedImage(
            animatedImage: animatedImage,
            firstFrame: sampledFrames[0].image,
            frameCount: cgFrames.count,
            duration: totalDuration,
            totalByteCost: max(1024, totalByteCost),
            cgFrames: cgFrames,
            keyTimes: keyTimes
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
