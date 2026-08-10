//
//  AnimatedRemoteGIFView.swift
//  NuvioTV
//
//  Animated GIF overlay for collection folder focus art.
//  SwiftUI `AsyncImage` / `Image` only show the first frame. We decode frames
//  with ImageIO and advance them with per-frame delays (browser-compatible)
//  so playback speed matches the web.
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
                FrameAccurateGIFView(
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

// MARK: - Decoded multi-frame image

private final class DecodedAnimatedImage {
    let frames: [UIImage]
    /// Delay for each frame, in seconds (same length as `frames`).
    let delays: [TimeInterval]
    /// Total loop duration (sum of delays).
    let loopDuration: TimeInterval

    init(frames: [UIImage], delays: [TimeInterval]) {
        self.frames = frames
        self.delays = delays
        self.loopDuration = delays.reduce(0, +)
    }

    var isAnimated: Bool { frames.count > 1 }
}

// MARK: - Frame-accurate player (UIView)

/// Advances frames with a display-linked timer using each frame's real delay.
/// Avoids `UIImage.animatedImage`, which equalizes frame times and was also
/// padded with a `max(total, count * 0.1)` floor that made GIFs play slow.
private final class FrameAccurateGIFUIView: UIImageView {
    private var decoded: DecodedAnimatedImage?
    private var frameIndex = 0
    private var displayLink: CADisplayLink?
    private var frameElapsed: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var wantsPlaying = false

    func setDecoded(_ decoded: DecodedAnimatedImage?, playing: Bool) {
        let sameInstance = self.decoded === decoded
        self.decoded = decoded
        wantsPlaying = playing

        if !sameInstance {
            frameIndex = 0
            frameElapsed = 0
            lastTimestamp = 0
            image = decoded?.frames.first
        }

        if playing, let decoded, decoded.isAnimated {
            startDisplayLink()
        } else {
            stopDisplayLink()
            if let decoded, !decoded.frames.isEmpty {
                // Freeze on first frame when not playing.
                image = decoded.frames[0]
                frameIndex = 0
                frameElapsed = 0
            }
        }
    }

    deinit {
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Match display refresh; we accumulate time against per-frame delays.
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard wantsPlaying, let decoded, decoded.isAnimated else { return }
        let frames = decoded.frames
        let delays = decoded.delays
        guard frames.count == delays.count, !frames.isEmpty else { return }

        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        // Ignore huge gaps (backgrounding / hitch) so we don't skip a full loop.
        frameElapsed += min(dt, 0.25)

        var safety = 0
        while safety < frames.count {
            safety += 1
            let delay = max(delays[frameIndex], 0.01)
            if frameElapsed < delay { break }
            frameElapsed -= delay
            frameIndex = (frameIndex + 1) % frames.count
            image = frames[frameIndex]
        }
    }
}

private struct FrameAccurateGIFView: UIViewRepresentable {
    let decoded: DecodedAnimatedImage
    var isPlaying: Bool
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> FrameAccurateGIFUIView {
        let view = FrameAccurateGIFUIView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: FrameAccurateGIFUIView, context: Context) {
        uiView.contentMode = contentMode
        uiView.setDecoded(decoded, playing: isPlaying)
    }

    static func dismantleUIView(_ uiView: FrameAccurateGIFUIView, coordinator: ()) {
        uiView.setDecoded(nil, playing: false)
    }
}

// MARK: - Cache + decode

private final class AnimatedGIFCache {
    static let shared = AnimatedGIFCache()

    private let cache = NSCache<NSString, DecodedAnimatedImage>()
    private var inFlight: [String: Task<DecodedAnimatedImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 16
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
            cache.setObject(image, forKey: key as NSString)
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

    private static func makeDecodedImage(from data: Data) -> DecodedAnimatedImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(frames: [still], delays: [0.1])
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(frames: [still], delays: [0.1])
        }

        var frames: [UIImage] = []
        var delays: [TimeInterval] = []
        frames.reserveCapacity(count)
        delays.reserveCapacity(count)

        // Decode at card-ish resolution so frame advances stay real-time.
        // Full Giphy frames are often 480p+ and thrash memory on Apple TV.
        let maxPixelSize = 640

        for index in 0..<count {
            guard let cgImage = createFrameImage(source: source, index: index, maxPixelSize: maxPixelSize) else {
                continue
            }
            frames.append(UIImage(cgImage: cgImage))
            delays.append(frameDelay(source: source, index: index))
        }

        guard !frames.isEmpty else {
            guard let still = UIImage(data: data) else { return nil }
            return DecodedAnimatedImage(frames: [still], delays: [0.1])
        }
        // Keep delays aligned if some frames failed to decode.
        if delays.count != frames.count {
            let avg = delays.isEmpty ? 0.1 : delays.reduce(0, +) / Double(delays.count)
            delays = Array(repeating: avg, count: frames.count)
        }
        return DecodedAnimatedImage(frames: frames, delays: delays)
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
            return thumb
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    /// Browser-compatible GIF frame delay in seconds.
    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        let defaultDelay: TimeInterval = 0.1
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [AnyHashable: Any]
        else { return defaultDelay }

        let gif = properties[kCGImagePropertyGIFDictionary] as? [AnyHashable: Any]
        let png = properties[kCGImagePropertyPNGDictionary] as? [AnyHashable: Any]

        // ImageIO may surface delays as NSNumber *or* Double — both must work.
        let unclamped = numberValue(gif?[kCGImagePropertyGIFUnclampedDelayTime])
            ?? numberValue(png?[kCGImagePropertyAPNGUnclampedDelayTime])
        let clamped = numberValue(gif?[kCGImagePropertyGIFDelayTime])
            ?? numberValue(png?[kCGImagePropertyAPNGDelayTime])

        var delay = unclamped ?? clamped ?? defaultDelay
        // GIF89a / browser rule: delays under 20ms are treated as 100ms.
        if delay < 0.02 {
            delay = defaultDelay
        }
        return delay
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
}
#endif
