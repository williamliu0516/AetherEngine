import CoreGraphics
import Foundation
import Vision

/// Phase D: on-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text
/// cues for the native WebVTT rendition (PiP / AirPlay / external display). Lossy by design;
/// a failed or empty recognition drops that cue and the rendition just misses the line, the
/// fullscreen overlay keeps the pixel-accurate bitmaps.
enum SubtitleImageOCR {
    private static let executor = Executor()

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

    /// The least confidence a recognised line keeps (`VNRecognizedText.confidence`, 0...1). Below it a line is more
    /// likely an outline, a sign's fragment or noise than words: a cue whose lines all fall below reads as nothing, and
    /// its picture stays as it is with no words beside it. Vision's accurate model answers 0.3, 0.5 or 1.0 for most
    /// real subtitle lines; the floor sits under its lowest.
    static let minimumConfidence: Float = 0.2

    /// `assembleLines` over the lines at `floor` or above.
    nonisolated static func assembleLines(_ observations: [(text: String, midY: CGFloat, confidence: Float)],
                                          floor: Float = minimumConfidence) -> String? {
        assembleLines(observations.filter { $0.confidence >= floor }.map { (text: $0.text, midY: $0.midY) })
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

    /// Vision synchronously waits for work of its own. Keep that wait on a real thread, not a
    /// Swift cooperative worker (including Task.detached), so recognition cannot exhaust the
    /// executor. Admission is process-wide and stays occupied until the native call returns,
    /// even if its caller is cancelled.
    nonisolated static func recognizeText(
        in image: CGImage, language: String?,
        recognition: @escaping @Sendable (CGImage, String?) -> String? = recognizeSynchronously
    ) async -> String? {
        await executor.run {
            recognition(image, language)
        }
    }

    /// `recognizeText`, once per picture: what a picture read (or that it read as nothing) is kept by its pixels and
    /// the language asked (`Readings`), so the native rendition and the host's translated second line
    /// (`AetherEngine.recognizedText(in:trackLanguage:)`), which ask for the same cues, recognise each once. A
    /// cancelled call keeps nothing. `readings` nil reads every time.
    /// A failed pass is not kept: the picture is read again when next asked. Nil when the call was cancelled before
    /// its turn.
    nonisolated static func read(
        _ image: CGImage, language: String?, readings: Readings? = SubtitleImageOCR.readings,
        recognition: @escaping @Sendable (CGImage, String?) -> Reading = recognizeReading
    ) async -> Reading? {
        let key = readings == nil ? nil : Readings.Key(picture: fingerprint(image), language: language)
        if let readings, let key, let kept = await readings.reading(key) { return kept.map(Reading.words) ?? .nothing }
        guard let reading = await executor.run({ recognition(image, language) }) else { return nil }
        if let readings, let key, reading != .failed, !Task.isCancelled { await readings.keep(reading.text, for: key) }
        return reading
    }

    /// The readings kept, text only (the pictures are not), the oldest let go past `capacity`.
    static let readings = Readings()

    actor Readings {
        struct Key: Hashable, Sendable {
            let picture: Int
            let language: String?

            init?(picture: Int?, language: String?) {
                guard let picture else { return nil }
                self.picture = picture
                self.language = language
            }
        }

        static let capacity = 2_000
        private var kept: [Key: String?] = [:]
        private var order: [Key] = []

        /// The kept reading: `.some(nil)` for a picture that read as nothing, nil for one not read.
        func reading(_ key: Key) -> String?? { kept[key] }

        func keep(_ text: String?, for key: Key) {
            if kept.updateValue(text, forKey: key) == nil { order.append(key) }
            if order.count > Self.capacity { kept.removeValue(forKey: order.removeFirst()) }
        }

        func removeAll() {
            kept = [:]
            order = []
        }
    }

    /// A picture's identity by its pixels and size (a cue's id can come again for another picture after a seek or on
    /// another track); nil where its bytes cannot be read, which is then read every time.
    nonisolated static func fingerprint(_ image: CGImage) -> Int? {
        guard let data = image.dataProvider?.data else { return nil }
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        hasher.combine(image.bytesPerRow)
        // How the bytes are read: the same bytes as another layout or colour space are another picture (Codex's
        // review of subtitle-ocr, 2026-11-05).
        hasher.combine(image.bitsPerPixel)
        hasher.combine(image.bitsPerComponent)
        hasher.combine(image.bitmapInfo.rawValue)
        hasher.combine(image.alphaInfo.rawValue)
        hasher.combine(image.colorSpace?.name as String?)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
        return hasher.finalize()
    }

    /// One synchronous Vision pass, called only by the recognition thread.
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
    nonisolated static func recognizeSynchronously(_ image: CGImage, language: String?) -> String? {
        recognizeReading(image, language: language).text
    }

    /// One recognition's outcome: words, a pass that ran and read none, or a pass that could not run (both models'
    /// requests failed, the picture could not be drawn), which says nothing of the picture and is never kept
    /// (`read`: kept as "no words", the native rendition dropped that line for good).
    enum Reading: Sendable, Equatable {
        case words(String)
        case nothing
        case failed

        var text: String? { if case .words(let text) = self { text } else { nil } }
    }

    /// `recognizeSynchronously`, saying a failed pass from one that read nothing.
    nonisolated static func recognizeReading(_ image: CGImage, language: String?) -> Reading {
        guard let flat = flattenedOntoBlack(image) else { return .failed }
        if !accurateIsUnavailable, let observations = recognize(flat, at: .accurate, language: language) {
            return assembleLines(observations).map(Reading.words) ?? .nothing
        }
        markAccurateUnavailable()
        guard let observations = recognize(flat, at: .fast, language: language) else { return .failed }
        return assembleLines(observations).map(Reading.words) ?? .nothing
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
                                              language: String?) -> [(text: String, midY: CGFloat, confidence: Float)]? {
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
        return (request.results ?? []).compactMap { obs -> (String, CGFloat, Float)? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, obs.boundingBox.midY, top.confidence)
        }
    }

    /// Recognize a batch of CLOSED cues and append the text results to a native store. Image
    /// cues become text cues at the same times; text cues pass through (mixed external files).
    /// The worker/fill task awaits each recognition; Vision itself runs on a dedicated thread.
    nonisolated static func appendRecognized(
        cues: [SubtitleCue], language trackLanguage: String?, to store: NativeSubtitleCueStore,
        readings: Readings? = SubtitleImageOCR.readings,
        recognition: @escaping @Sendable (CGImage, String?) -> Reading = recognizeReading
    ) async {
        let language = recognitionLanguage(forTrackLanguage: trackLanguage)
        var out: [SubtitleCue] = []
        for cue in cues {
            if Task.isCancelled { break }
            switch cue.body {
            case .image(let image):
                if let text = await read(image.cgImage, language: language, readings: readings,
                                         recognition: recognition)?.text {
                    out.append(cue.with(body: .text(text)))
                }
            case .text, .richText:
                out.append(cue)
            }
        }
        if !out.isEmpty { store.appendCues(out) }
    }

    /// Waiters suspend; only the admitted operation owns a thread. Cancellation removes a queued
    /// request, but cannot release an active request's slot while Vision is still using it.
    actor Executor {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Bool, Never>
        }

        private var busy = false
        private var waiting: [Waiter] = []
        var pendingCount: Int { waiting.count }

        func run<Result: Sendable>(_ recognition: @escaping @Sendable () -> Result?) async -> Result? {
            guard await acquire() else { return nil }
            guard !Task.isCancelled else {
                release()
                return nil
            }
            let result = await withCheckedContinuation { continuation in
                let worker = Thread {
                    let result = autoreleasepool(invoking: recognition)
                    continuation.resume(returning: result)
                }
                worker.name = "com.aetherengine.subtitle.ocr"
                worker.qualityOfService = .utility
                worker.start()
            }
            release()
            return result
        }

        private func acquire() async -> Bool {
            let id = UUID()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return false }
                if !busy {
                    busy = true
                    return true
                }
                return await withCheckedContinuation {
                    waiting.append(Waiter(id: id, continuation: $0))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: index).continuation.resume(returning: false)
        }

        private func release() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().continuation.resume(returning: true)
            }
        }
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
