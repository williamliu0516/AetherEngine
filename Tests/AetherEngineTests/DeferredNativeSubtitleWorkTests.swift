import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// `LoadOptions.deferNativeSubtitleWork` and `setNativeSubtitleTiming`: the native renditions' extra work only
/// while the host shows one, and the host's retiming carried into what they serve.
@Suite("Deferred native subtitle work", .serialized)
struct DeferredNativeSubtitleWorkTests {

    private func text(_ id: Int, _ start: Double, _ end: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(s))
    }

    private func image(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let picture = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero, canvasSize: .zero)
        return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(picture))
    }

    // MARK: - The decision

    @Test("the OCR runs always by default, and only while a rendition is shown when deferred")
    func ocrWanted() {
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: false, renderingRequested: false))
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: false, renderingRequested: true))
        #expect(!AetherEngine.nativeSubtitleOCRWanted(deferWork: true, renderingRequested: false))
        #expect(AetherEngine.nativeSubtitleOCRWanted(deferWork: true, renderingRequested: true))
    }

    // MARK: - Arming with the rendering request

    /// An engine whose active subtitle is embedded bitmap stream 5, ordinal 0 of the native table.
    @MainActor
    private func bitmapEngine(deferWork: Bool) throws -> AetherEngine {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.prepareNativeSubtitles = true
        options.deferNativeSubtitleWork = deferWork
        engine.setLoadedOptionsForTesting(options)
        engine.nativeSubtitleTrackTable = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 5, language: "zh", needsOCR: true),
        ]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore()])
        engine.activeSubtitleTrackIndex = 5
        return engine
    }

    @MainActor
    @Test("deferred: the bitmap OCR arms when a rendition is shown and disarms when it is not")
    func armsWithRendering() throws {
        let engine = try bitmapEngine(deferWork: true)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == 0)
        engine.setNativeSubtitleRendering(false)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == 0, "a second PiP arms again")
        engine.cancelSubtitleOCRWorker()
    }

    @MainActor
    @Test("not deferred: the rendering request leaves the OCR as the selection set it")
    func defaultLeavesTheWorker() throws {
        let engine = try bitmapEngine(deferWork: false)
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == nil, "only a selection arms it without the option")
        engine.startSubtitleOCRWorker(ordinal: 0, streamIndex: 5)
        engine.setNativeSubtitleRendering(false)
        #expect(engine.subtitleOCRArmedOrdinal == 0, "a closed PiP must not stop it without the option")
        engine.cancelSubtitleOCRWorker()
    }

    @MainActor
    @Test("deferred: a text track arms no OCR")
    func textTrackArmsNothing() throws {
        let engine = try bitmapEngine(deferWork: true)
        engine.nativeSubtitleTrackTable = [AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 5, language: "zh")]
        engine.setNativeSubtitleRendering(true)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("deferred: a .sup sidecar's fill waits for a shown rendition, then runs")
    func sidecarFillWaits() async throws {
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

        engine.startSidecarOCRFillIfNeeded(externalTrackID: id, cues: [image(1, 10, 12)])
        #expect(engine.subtitleOCRSidecarFillTask == nil)
        #expect(engine.deferredSidecarOCRFill?.externalTrackID == id)

        engine.setNativeSubtitleRendering(true)
        let fill = try #require(engine.subtitleOCRSidecarFillTask)
        await fill.value
        #expect(store.isFinished)
        engine.resetSubtitleOCRState()
        #expect(engine.deferredSidecarOCRFill == nil)
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
}
