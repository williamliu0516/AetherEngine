import Testing
import Foundation
@testable import AetherEngine

/// A forward seek a few segments ahead of the producer waits for its march only when the march is quicker than a
/// restart: three 18 MB segments of a 37 Mbit/s file over a 40 Mbit/s share took 10.8 s to pump through (A12Z iPad,
/// 2026-10-17), against a restart's reopen plus the one segment.
@Suite("Forward march pace")
struct ForwardMarchPaceTests {

    @Test("restart when the segments before the one asked for take longer than a reopen")
    func decision() {
        let slow = VideoSegmentProvider.forwardMarchSlowerThanRestart
        #expect(slow(3, 3.6))            // the device case: 2 x 3.6 s to pump through
        #expect(!slow(3, 0.2))           // a LAN source: 0.4 s, waiting is quicker
        #expect(!slow(1, 10))            // the very next segment: nothing to pump through
        #expect(!slow(5, nil))           // pace unknown: the old window rule alone
        #expect(slow(9, 0.2))            // 1.6 s even on a fast source
    }

    @Test("the pace is the quickest recent step, and old steps do not count")
    func fastestStep() {
        let steps: [(seconds: Double, at: Double)] = [(4.0, 100), (0.5, 150), (3.0, 290)]
        #expect(SegmentCache.fastestStep(steps, now: 300) == 3.0, "the 0.5 s step is older than two minutes")
        #expect(SegmentCache.fastestStep(steps, now: 200) == 0.5)
        #expect(SegmentCache.fastestStep([], now: 0) == nil)
    }

    @Test("consecutive stores give a pace, a park in between does not")
    func paceFromStores() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        cache.store(index: 0, data: Data(count: 16))
        #expect(cache.fastestRecentSegmentSeconds == nil, "one store is no step")
        cache.noteMarchParked()
        cache.store(index: 1, data: Data(count: 16))
        #expect(cache.fastestRecentSegmentSeconds == nil, "a step across a park is playback's pace")
        cache.store(index: 2, data: Data(count: 16))
        let pace = try #require(cache.fastestRecentSegmentSeconds)
        #expect(pace >= 0 && pace < 5)
    }
}
