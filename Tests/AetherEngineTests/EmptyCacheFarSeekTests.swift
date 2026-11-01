import Testing
import Foundation
@testable import AetherEngine

/// A far seek that comes while the producer still writes its first segment restarts at once when the march is slower
/// than a restart: the producer covering the index vetoed it, and the request waited for the march until AVPlayer gave
/// it up (a 16 Mbit/s AV1 clip over a 26 Mbit/s SMB link: seg6 asked 1.5 s after the start, served 8.1 s later, the
/// seek moving after 11.9 s; iPad, 2026-11-01). With no segment stored the pace is the segment at the source's
/// bitrate over the pump's read rate. A quick march, and an AVPlayer prefetch that no seek asked for, keep the veto
/// (#93 residual, AE#141; Codex).
@Suite(.offCooperativePool)
struct EmptyCacheFarSeekTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        func record(_ idx: Int) { lock.lock(); fired.append(idx); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// The AV1 clip's plan: nine 6.7 s segments of a 16 Mbit/s source (the last `lastSeconds` long), the producer
    /// anchored at 0 with none stored.
    private func makeProvider(cache: SegmentCache, recorder: Recorder, slice: TimeInterval,
                              lastSeconds: Double = 6.7) -> VideoSegmentProvider {
        let segments = (0..<9).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 6700, endPts: Int64(i) * 6700 + 6700,
                                   startSeconds: Double(i) * 6.7, durationSeconds: i == 8 ? lastSeconds : 6.7)
        }
        return VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "av01", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 16_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                cache?.store(index: idx, data: Data(repeating: 0x41, count: 8))
            },
            restartActivity: { false },
            activeProducerBase: { 0 },
            producerFinished: { false },
            initialRestartIndex: 0,
            repositionWaitSlice: slice,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: 0.3
        )
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    @Test("a far seek before the first segment is stored restarts at once over a slow link")
    func slowLinkRestartsAtOnce() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        cache.notePumpRate(bytesPerSecond: 3_300_000)
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 2)
        provider.noteSeekTarget(6)

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 6)
        #expect(served != nil)
        #expect(recorder.all == [6])
        #expect(seconds(since: start) < 1.5)
    }

    @Test("a pace that becomes known while the request waits restarts within a second of it")
    func paceKnownDuringTheWait() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 8)
        provider.noteSeekTarget(6)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.5)
            cache.notePumpRate(bytesPerSecond: 3_300_000)
        }

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 6)
        #expect(served != nil)
        #expect(recorder.all == [6])
        #expect(seconds(since: start) < 3)
    }

    @Test("a quick march keeps the producer's veto")
    func quickMarchKeepsTheVeto() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        // 13.4 MB a segment at 60 MB/s: five segments in 1.1 s, quicker than a restart's 1.5 s.
        cache.notePumpRate(bytesPerSecond: 60_000_000)
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 0.2)
        provider.noteSeekTarget(6)

        #expect(provider.mediaSegment(at: 6) == nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("a prefetch no seek asked for keeps the producer's veto, however slow the link")
    func prefetchKeepsTheVeto() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        cache.notePumpRate(bytesPerSecond: 3_300_000)
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 0.2)

        #expect(provider.mediaSegment(at: 6) == nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("a pace found slow in the last slice still restarts")
    func slowInTheLastSlice() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        // Three 0.4 s slices; the rate arrives in the third.
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 0.4)
        provider.noteSeekTarget(6)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.9)
            cache.notePumpRate(bytesPerSecond: 3_300_000)
        }

        #expect(provider.mediaSegment(at: 6) != nil)
        #expect(recorder.all == [6])
    }

    @Test("a short last segment does not hide a slow march to it")
    func shortLastSegment() {
        let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)
        defer { cache.close() }
        let recorder = Recorder()
        cache.notePumpRate(bytesPerSecond: 3_300_000)
        let provider = makeProvider(cache: cache, recorder: recorder, slice: 2, lastSeconds: 0.1)
        provider.noteSeekTarget(8)

        #expect(provider.mediaSegment(at: 8) != nil)
        #expect(recorder.all == [8])
    }

    @Test("the planned pace is a segment's bytes at the source's bitrate over the read rate")
    func plannedPace() {
        let pace = VideoSegmentProvider.plannedSecondsPerSegment
        #expect(pace(6.7, 16_000_000, 3_300_000).map { abs($0 - 4.06) < 0.01 } == true)
        #expect(pace(6.7, 0, 3_300_000) == nil, "bitrate unknown")
        #expect(pace(6.7, 16_000_000, nil) == nil, "no read rate yet")
    }
}
