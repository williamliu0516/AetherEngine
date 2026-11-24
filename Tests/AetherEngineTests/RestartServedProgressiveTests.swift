import Testing
import Foundation
@testable import AetherEngine

/// W3160: a segment a seek's restart serves while the producer still writes it reports `.served` at its last byte, not
/// its first. Its 1 s re-seek grace started at the first byte, so on a 51 Mbps line AVPlayer was re-sought while the
/// rest was still arriving: three re-seeks per far seek before the picture. A whole segment still reports at once, an
/// undelivered one still reports `.undelivered`.
///
/// W3164: its first byte reports `.streaming`, so the target counts as served at once. On a slow line the 8 s seek
/// deadline could fire while the target still streamed, and with no served mark it re-anchored the producer that was
/// delivering it (G2UU, a slow netdisk line).
@Suite(.offCooperativePool, .serialized)
struct RestartServedProgressiveTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [RestartServedEvent] = []
        private var handles: [FileHandle] = []
        func add(_ event: RestartServedEvent) { lock.withLock { _events.append(event) } }
        var events: [RestartServedEvent] { lock.withLock { _events } }
        func keep(_ handle: FileHandle) { lock.withLock { handles.append(handle) } }
        func closeAll() { lock.withLock { handles.forEach { try? $0.close() } } }
    }

    /// 100 four-second segments, progressive delivery on; the producer plays at 70 with 68...70 resident. A restart
    /// either starts writing the segment it was asked for (`whole: false`) or stores it whole.
    private func makeProvider(cache: SegmentCache, recorder: Recorder, whole: Bool) -> VideoSegmentProvider {
        let segments = (0..<100).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i) * 4000 + 4000,
                                   startSeconds: Double(i) * 4, durationSeconds: 4)
        }
        for i in 68...70 { cache.store(index: i, data: Data(repeating: 0x41, count: 8)) }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "dvh1.05.06", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .pq, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 50_000_000,
            servesSegmentsProgressively: true,
            restartHandler: { [weak cache] idx in
                guard let cache else { return }
                if whole {
                    cache.store(index: idx, data: Data(repeating: 0x42, count: 8))
                    return
                }
                let url = cache.sessionDir.appendingPathComponent("staging-seg-\(idx)-\(UUID().uuidString.prefix(8)).tmp")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                handle.write(Data(repeating: 0x43, count: 64))
                recorder.keep(handle)
                cache.beginInProgress(index: idx, stagingPath: url)
            },
            restartActivity: { false },
            activeProducerBase: { 68 },
            producerFinished: { false },
            initialRestartIndex: 68,
            repositionWaitSlice: 0.1,
            repositionRideCapSeconds: 1.0,
            forwardBackpressureWaitSeconds: 0.1
        )
        provider.restartServedHandler = { _, _, event in recorder.add(event) }
        #expect(provider.mediaSegment(at: 70) != nil)
        return provider
    }

    private func makeCache() -> SegmentCache {
        SegmentCache(forwardWindow: 40, backwardWindow: 40, baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("restart served \(UUID().uuidString)", isDirectory: true))
    }

    @Test("a segment served while it is written is marked streaming at its first byte, served at its last")
    func progressiveReportsAtLastByte() {
        let cache = makeCache()
        let recorder = Recorder()
        defer { recorder.closeAll(); cache.close() }
        let provider = makeProvider(cache: cache, recorder: recorder, whole: false)

        provider.noteSeekTarget(90)
        guard case .progressive = provider.mediaSegmentSource(at: 90, onSlow: nil) else {
            Issue.record("the restart's segment is served while it is written"); return
        }
        #expect(recorder.events == [.streaming],
                "the target counts as served from its first byte, so the seek deadline does not re-anchor it")
        provider.didServeMediaSegment(index: 90, delivered: true)
        #expect(recorder.events == [.streaming, .served])
        provider.didServeMediaSegment(index: 90, delivered: true)
        #expect(recorder.events == [.streaming, .served], "a second serve of the segment reports nothing more")
    }

    @Test("a segment served while it is written and never delivered reports undelivered")
    func progressiveUndelivered() {
        let cache = makeCache()
        let recorder = Recorder()
        defer { recorder.closeAll(); cache.close() }
        let provider = makeProvider(cache: cache, recorder: recorder, whole: false)

        provider.noteSeekTarget(90)
        guard case .progressive = provider.mediaSegmentSource(at: 90, onSlow: nil) else {
            Issue.record("the restart's segment is served while it is written"); return
        }
        provider.didServeMediaSegment(index: 90, delivered: false)
        #expect(recorder.events == [.streaming, .undelivered])
    }

    @Test("a whole segment reports served at once, and its delivery adds nothing")
    func wholeReportsAtOnce() {
        let cache = makeCache()
        let recorder = Recorder()
        defer { recorder.closeAll(); cache.close() }
        let provider = makeProvider(cache: cache, recorder: recorder, whole: true)

        provider.noteSeekTarget(90)
        guard case .data = provider.mediaSegmentSource(at: 90, onSlow: nil) else {
            Issue.record("a stored segment is served whole"); return
        }
        #expect(recorder.events == [.served])
        provider.didServeMediaSegment(index: 90, delivered: true)
        #expect(recorder.events == [.served])
    }
}
