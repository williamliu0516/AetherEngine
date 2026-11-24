import Testing
import Foundation
@testable import AetherEngine

/// W3146: after a seek's own run has begun, a late request for the place the seek left is answered from the cache or
/// refused, and never moves the producer back there (a 4K Dolby Vision film from a cloud drive: a stale seg70 GET
/// after the seek re-anchored the producer, then the seek's next request re-anchored it again; the picture after
/// 14.8 s). A seek AVPlayer serves from its own buffer, a request asked again, and a later seek keep the usual path.
@Suite(.offCooperativePool)
struct StaleSeekFetchTests {

    private final class Producer: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        private var _base: Int
        init(base: Int) { _base = base }
        func restart(_ idx: Int) { lock.withLock { fired.append(idx); _base = idx } }
        var restarts: [Int] { lock.withLock { fired } }
        var base: Int { lock.withLock { _base } }
    }

    /// 100 four-second segments; the producer plays at 70 with 68...70 resident. A restart stores the segment it was
    /// asked for, as a producer delivering it would.
    private func makeProvider(cache: SegmentCache, producer: Producer) -> VideoSegmentProvider {
        let segments = (0..<100).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i) * 4000 + 4000,
                                   startSeconds: Double(i) * 4, durationSeconds: 4)
        }
        for i in 68...70 { cache.store(index: i, data: Data(repeating: 0x41, count: 8)) }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "dvh1.05.06", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .pq, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 50_000_000,
            restartHandler: { [weak cache] idx in
                producer.restart(idx)
                cache?.store(index: idx, data: Data(repeating: 0x42, count: 8))
            },
            restartActivity: { false },
            activeProducerBase: { producer.base },
            producerFinished: { false },
            initialRestartIndex: 68,
            repositionWaitSlice: 0.1,
            repositionRideCapSeconds: 1.0,
            forwardBackpressureWaitSeconds: 0.1
        )
        // AVPlayer has been playing up to the place the seek leaves.
        #expect(provider.mediaSegment(at: 70) != nil)
        return provider
    }

    @Test("a late request for the place a forward seek left neither moves the producer nor waits")
    func forwardSeekStaleRequestIsRefused() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        defer { cache.close() }
        let producer = Producer(base: 68)
        let provider = makeProvider(cache: cache, producer: producer)

        provider.noteSeekTarget(90)
        #expect(provider.mediaSegment(at: 90) != nil)
        #expect(producer.restarts == [90])

        // AVPlayer's request from before the seek, arriving now.
        let start = DispatchTime.now()
        #expect(provider.mediaSegmentURL(at: 71) == nil)
        #expect(provider.mediaSegment(at: 71) == nil, "a stale request for a segment nobody has is refused")
        #expect(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 < 0.5)
        #expect(producer.restarts == [90], "the stale request moved the producer: \(producer.restarts)")

        // The seek's run goes on with the producer it has.
        _ = provider.mediaSegment(at: 91)
        #expect(producer.restarts == [90])
    }

    @Test("a late request for a resident segment of the old place is served from the cache, the producer kept")
    func staleResidentRequestIsServedFromTheCache() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        defer { cache.close() }
        let producer = Producer(base: 68)
        let provider = makeProvider(cache: cache, producer: producer)

        provider.noteSeekTarget(90)
        #expect(provider.mediaSegment(at: 90) != nil)
        #expect(provider.mediaSegment(at: 69) != nil)
        #expect(producer.restarts == [90])
    }

    @Test("a late request for the place a backward seek left does not move the producer")
    func backwardSeekStaleRequestIsRefused() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        defer { cache.close() }
        let producer = Producer(base: 68)
        let provider = makeProvider(cache: cache, producer: producer)

        provider.noteSeekTarget(29)
        #expect(provider.mediaSegment(at: 28) != nil, "AVPlayer may ask the segment before the target first")
        #expect(provider.mediaSegment(at: 71) == nil)
        #expect(producer.restarts == [28])
    }

    @Test("a refused request asked again is wanted, and a later seek still restarts")
    func askedAgainOrSoughtAgainRestarts() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        defer { cache.close() }
        let producer = Producer(base: 68)
        let provider = makeProvider(cache: cache, producer: producer)

        provider.noteSeekTarget(90)
        #expect(provider.mediaSegment(at: 90) != nil)
        #expect(provider.mediaSegment(at: 71) == nil)
        #expect(provider.mediaSegment(at: 71) != nil, "asked again, AVPlayer wants it")
        #expect(producer.restarts == [90, 71])

        provider.noteSeekTarget(40)
        #expect(provider.mediaSegment(at: 40) != nil)
        #expect(producer.restarts == [90, 71, 40])
    }

    @Test("a seek AVPlayer serves from its own buffer opens no window")
    func inBufferSeekKeepsTheUsualPath() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        defer { cache.close() }
        let producer = Producer(base: 68)
        let provider = makeProvider(cache: cache, producer: producer)

        // A seek back to 60 within AVPlayer's buffer asks nothing at 59 or 60. A request far from 60 (which an open
        // window would refuse) then takes the usual path: here, a restart.
        provider.noteSeekTarget(60)
        #expect(provider.mediaSegment(at: 85) != nil)
        #expect(producer.restarts == [85])
    }

    @Test("the window opens at the seek's own request and closes after its time")
    func windowTiming() {
        var guardState = StaleSeekFetchGuard()
        guardState.noteSeek(index: 90, now: 100)
        #expect(!guardState.isStale(71, now: 100.5), "not open before the seek's own request")
        guardState.noteWanted(89, now: 101)
        #expect(guardState.isStale(71, now: 101.1))
        #expect(!guardState.isStale(95, now: 101.1), "the run's own segments ahead")
        guardState.noteWanted(95, now: 102)
        #expect(!guardState.isStale(103, now: 102.1), "the front moves with the run")
        #expect(!guardState.isStale(71, now: 101 + StaleSeekFetchGuard.openSeconds + 0.1), "closed after its time")

        var late = StaleSeekFetchGuard()
        late.noteSeek(index: 90, now: 100)
        late.noteWanted(90, now: 100 + StaleSeekFetchGuard.openSeconds + 1)
        #expect(!late.isStale(71, now: 112), "a run that began after the window opens nothing")
    }
}
