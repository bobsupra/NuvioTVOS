import CoreGraphics
import Foundation
import Vision

/// Phase D: on-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text
/// cues for the native WebVTT rendition (PiP / AirPlay / external display). Lossy by design;
/// a failed or empty recognition drops that cue and the rendition just misses the line, the
/// fullscreen overlay keeps the pixel-accurate bitmaps.
enum SubtitleImageOCR {

    /// Vision bounding boxes are normalized with a bottom-left origin; reading order is
    /// descending midY. Blank fragments are dropped; nil when nothing readable remains.
    nonisolated static func assembleLines(_ observations: [(text: String, midY: CGFloat)]) -> String? {
        let lines = observations
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), midY: $0.midY) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.midY > $1.midY }
            .map(\.text)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Track tags are ISO 639-1/2 ("ger"), Vision wants BCP-47 primary codes ("de"). The engine's
    /// synonym classes resolve the bibliographic 639-2/B forms Foundation cannot ("ger", "fre").
    nonisolated static func recognitionLanguage(forTrackLanguage tag: String?) -> String? {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if let set = AetherEngine.languageSynonyms.first(where: { $0.contains(raw) }),
           let twoLetter = set.first(where: { $0.count == 2 }) {
            return twoLetter
        }
        return Locale.LanguageCode(raw).identifier(.alpha2) ?? raw
    }

    /// Subtitle bitmaps are white glyphs with an outline on transparency; an opaque black
    /// backing gives Vision stable contrast.
    nonisolated static func flattenedOntoBlack(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// One synchronous Vision pass; callers serialize (single worker task / single fill task).
    ///
    /// `.accurate` is the better reader and it is also an OPTIONAL system model: it runs on the
    /// Neural Engine and a given OS build may be unable to hand it over. Measured on macOS 27.0,
    /// the first accurate request in a process spends about a minute precompiling it and then
    /// throws `e5rtError(…precompiled_compute_operation…, 13)` roughly half the time, after which
    /// every later accurate request in that process fails in milliseconds (#552).
    ///
    /// Pinning it alone meant the whole bitmap-to-text stage yielded nothing wherever that happens,
    /// so PGS / DVB / DVD subtitles were simply absent in PiP, on AirPlay and on an external
    /// display, while `.fast` read the very same frame correctly in 30 ms. So a failed pass drops
    /// to `.fast` instead of dropping the cue.
    ///
    /// The drop is remembered for the process. A single accurate failure is not a fluke on this
    /// evidence, it is the state the process stays in, and the alternative is paying a minute of
    /// stall per cue to learn it again.
    nonisolated static func recognizeText(in image: CGImage, language: String?) -> String? {
        guard let flat = flattenedOntoBlack(image) else { return nil }
        if !accurateIsUnavailable, let observations = recognize(flat, at: .accurate, language: language) {
            return assembleLines(observations)
        }
        markAccurateUnavailable()
        guard let observations = recognize(flat, at: .fast, language: language) else { return nil }
        return assembleLines(observations)
    }

    /// nil when the REQUEST failed, which is what the fallback turns on. An empty array is a
    /// request that ran and read nothing, which is an ordinary outcome for a subtitle bitmap and
    /// says nothing about the model.
    ///
    /// The language is resolved per level on purpose: `.fast` supports six languages against the
    /// accurate model's thirty-three, so outside those six the pin is simply dropped. Unpinned
    /// recognition of a line beats no line.
    private nonisolated static func recognize(_ image: CGImage,
                                              at level: VNRequestTextRecognitionLevel,
                                              language: String?) -> [(text: String, midY: CGFloat)]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        if let language,
           let supported = try? request.supportedRecognitionLanguages(),
           let match = supported.first(where: {
               let s = $0.lowercased()
               return s == language || s.hasPrefix(language + "-")
           }) {
            request.recognitionLanguages = [match]
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            logFailureOnce("Vision \(level == .accurate ? "accurate" : "fast") perform failed: \(error)")
            return nil
        }
        return (request.results ?? []).compactMap { obs -> (String, CGFloat)? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, obs.boundingBox.midY)
        }
    }

    /// Recognize a batch of CLOSED cues and append the text results to a native store. Image
    /// cues become text cues at the same times; text cues pass through (mixed external files).
    /// Runs inside a detached worker/fill task, never on the MainActor.
    nonisolated static func appendRecognized(cues: [SubtitleCue], language trackLanguage: String?,
                                             to store: NativeSubtitleCueStore) {
        let language = recognitionLanguage(forTrackLanguage: trackLanguage)
        var out: [SubtitleCue] = []
        for cue in cues {
            if Task.isCancelled { break }
            switch cue.body {
            case .image(let image):
                if let text = recognizeText(in: image.cgImage, language: language) {
                    out.append(cue.with(body: .text(text)))
                }
            case .text, .richText:
                out.append(cue)
            }
        }
        if !out.isEmpty { store.appendCues(out) }
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var loggedFailure = false
    nonisolated(unsafe) private static var accurateFailed = false

    private nonisolated static var accurateIsUnavailable: Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return accurateFailed
    }

    private nonisolated static func markAccurateUnavailable() {
        failureLock.lock()
        accurateFailed = true
        failureLock.unlock()
    }

    /// The fallback cannot be reached on a machine whose accurate model works, and a machine whose
    /// model is broken cannot be asked for on demand. So the state it turns on is settable, and the
    /// test drives the fallback rather than the weather.
    nonisolated static func setAccurateUnavailableForTesting(_ unavailable: Bool) {
        failureLock.lock()
        accurateFailed = unavailable
        failureLock.unlock()
    }

    private nonisolated static func logFailureOnce(_ reason: String) {
        failureLock.lock()
        let first = !loggedFailure
        loggedFailure = true
        failureLock.unlock()
        if first { EngineLog.emit("[SubtitleOCR] degraded: \(reason)", category: .engine) }
    }
}
