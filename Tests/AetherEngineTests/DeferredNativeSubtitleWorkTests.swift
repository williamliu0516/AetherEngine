import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.deferNativeSubtitleWork` and `setNativeSubtitleTiming`: a `.sup` sidecar's OCR only once the host
/// shows a rendition, and the host's retiming carried into what the renditions serve.
@Suite("Deferred native subtitle work", .serialized)
struct DeferredNativeSubtitleWorkTests {

    private func text(_ id: Int, _ start: Double, _ end: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(s))
    }

    // MARK: - The decision

    @Test("the OCR runs always by default, and only while a rendition is shown when deferred")
    func ocrWanted() {
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: false, renderingRequested: false))
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: false, renderingRequested: true))
        #expect(!AetherEngine.nativeSubtitleOCRWanted(deferWork: true, renderingRequested: false))
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: true, renderingRequested: true))
    }

    // MARK: - The sidecar's fill

    // An embedded bitmap track's OCR is armed only while its rendition is shown since 7.54, by the engine itself
    // (`syncSubtitleOCRWithNativeSelection`, upstream's tests); the option holds only the sidecar's whole-file fill.

    @MainActor
    @Test("deferred: a .sup sidecar's fill waits for a shown rendition, then runs")
    func sidecarFillWaits() async throws {
        let url = try Issue921SidecarBitmapDrainTests.writeSup(sets: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(try await SubtitleDecoder.decodeFile(url: url, keepsBitmapPackets: true).bitmapSource)
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.prepareNativeSubtitles = true
        options.deferNativeSubtitleWork = true
        engine.setLoadedOptionsForTesting(options)
        let id = AetherEngine.externalSubtitleTrackIDBase
        var entry = AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, language: "en", needsOCR: true)
        entry.externalID = id
        engine.nativeSubtitleTrackTable = [entry]
        let store = NativeSubtitleCueStore()
        engine.testHookInstallNativeStores([store])
        engine.activeSubtitleTrackIndex = id

        engine.startSidecarOCRFillIfNeeded(externalTrackID: id, source: source)
        #expect(engine.subtitleOCRSidecarFillTask == nil)
        #expect(engine.deferredSidecarOCRFill?.externalTrackID == id)

        engine.setNativeSubtitleRendering(true)
        let fill = try #require(engine.subtitleOCRSidecarFillTask)
        await fill.value
        #expect(store.isFinished)
        #expect(engine.deferredSidecarOCRFill == nil)
        engine.resetSubtitleOCRState()
    }

    @MainActor
    @Test("not deferred: a .sup sidecar's fill starts at once")
    func sidecarFillAtOnce() async throws {
        let url = try Issue921SidecarBitmapDrainTests.writeSup(sets: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(try await SubtitleDecoder.decodeFile(url: url, keepsBitmapPackets: true).bitmapSource)
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.prepareNativeSubtitles = true
        engine.setLoadedOptionsForTesting(options)
        let id = AetherEngine.externalSubtitleTrackIDBase
        var entry = AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, language: "en", needsOCR: true)
        entry.externalID = id
        engine.nativeSubtitleTrackTable = [entry]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore()])
        engine.startSidecarOCRFillIfNeeded(externalTrackID: id, source: source)
        let fill = try #require(engine.subtitleOCRSidecarFillTask)
        await fill.value
        #expect(engine.deferredSidecarOCRFill == nil)
        engine.resetSubtitleOCRState()
    }

    // MARK: - The host's timing

    @Test("a store serves its cues at scale * t + offset, before the playlist shift")
    func storeTiming() {
        let store = NativeSubtitleCueStore()
        store.setShiftSeconds(10)
        store.replaceCues([text(1, 100, 102, "a")])
        store.setTiming(scale: 1, offset: 2.5)                  // a 2.5 s delay
        var window = store.cuesInWindow(start: 0, end: 1_000)
        #expect(abs(window[0].start - 92.5) < 0.0001)
        #expect(abs(window[0].end - 94.5) < 0.0001)
        #expect(abs(store.readMaxCueEnd() - 94.5) < 0.0001)
        store.setTiming(scale: 25 / 23.976, offset: -1)         // a 25 fps file on a 23.976 fps video
        window = store.cuesInWindow(start: 0, end: 1_000)
        #expect(abs(window[0].start - (100 * 25 / 23.976 - 1 - 10)) < 0.0001)
        #expect(store.snapshotCues()[0].startTime == 100, "the overlay's own cues stay on the source axis")
    }

    @MainActor
    @Test("the engine keeps the host's timing and ignores what it cannot serve")
    func engineTiming() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleTiming(offset: 1.5)
        #expect(engine.nativeSubtitleTimingScale == 1)
        #expect(engine.nativeSubtitleTimingOffset == 1.5)
        engine.setNativeSubtitleTiming(scale: 0, offset: 3)
        engine.setNativeSubtitleTiming(scale: .nan, offset: 3)
        engine.setNativeSubtitleTiming(offset: .infinity)
        #expect(engine.nativeSubtitleTimingScale == 1)
        #expect(engine.nativeSubtitleTimingOffset == 1.5)
    }

    // MARK: - The host's text

    @Test("a store serves its cues through the host's text rewrite, with its own track's language")
    func storeText() {
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        stores[0].replaceCues([text(1, 1, 2, "后来发生了什么")])
        stores[1].replaceCues([text(2, 1, 2, "後來發生了什麼")])
        NativeSubtitleCueStore.setText({ text, language in
            language == "zh-Hans" ? text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
                                  : "\(language ?? "-"):\(text)"
        }, on: stores, languages: ["zh-Hans"])
        #expect(stores[0].allCues()[0].text == "後來發生了什麼")
        #expect(stores[0].cuesInWindow(start: 0, end: 5)[0].text == "後來發生了什麼")
        #expect(stores[1].allCues()[0].text == "-:後來發生了什麼", "a store past the languages gets nil")
        #expect(stores[0].snapshotCues()[0].text == "后来发生了什么", "the overlay's own cues keep the decoded text")
        #expect(WebVTTBuilder.body(cues: stores[0].allCues()).contains("後來發生了什麼"))
        NativeSubtitleCueStore.setText(nil, on: stores, languages: ["zh-Hans"])
        #expect(stores[0].allCues()[0].text == "后来发生了什么")
    }

    @MainActor
    @Test("the engine keeps the host's text rewrite until the host clears it")
    func engineText() throws {
        let engine = try AetherEngine()
        #expect(engine.nativeSubtitleTextTransform == nil)
        engine.setNativeSubtitleText { text, language in "\(language ?? "-"):\(text)" }
        #expect(engine.nativeSubtitleTextTransform?("a", "zh") == "zh:a")
        engine.setNativeSubtitleText(nil)
        #expect(engine.nativeSubtitleTextTransform == nil)
    }
}
