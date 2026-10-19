import Testing
import Foundation
@testable import AetherEngine

/// A seek target the producer serves after a restart the provider fired is re-sought at once, not at the 8 s deadline
/// (a DV clip's near-end seek on an A12Z iPad sat 2.3 s on a served target).
@Suite("Re-seek when a restart serves the target")
struct RestartServedReseekTests {

    @Test("the served segment holds the target within half a second of its window")
    func holdsTarget() {
        let holds = AetherEngine.restartServedSegmentHoldsSeekTarget
        #expect(holds(20.95, 24.95, 22))
        #expect(holds(20.95, 24.95, 20.6), "a target just before the cut lands in this segment")
        #expect(!holds(20.95, 24.95, 26))
        #expect(!holds(20.95, 24.95, 3))
    }
}

/// A restart-served target whose bytes never reached AVPlayer (it gave up on the request first) is re-sought at once
/// (A12Z iPad, 2026-10-19: -12889 at 4.0 s, the segment served at 5.3 s into a closed socket, a second waited for
/// nothing).
@Suite("Re-seek when the served target was not delivered")
struct RestartServedUndeliveredTests {

    @Test("only a failed send of the segment the restart served counts")
    func event() {
        let event = VideoSegmentProvider.restartServedEvent
        #expect(event(1921, 1921, false) == .undelivered)
        #expect(event(1921, 1921, true) == nil, "delivered: AVPlayer may still land from it")
        #expect(event(1922, 1921, false) == nil, "another segment says nothing about the target")
        #expect(event(1921, nil, false) == nil)
    }

    @Test("an undelivered target is re-sought at once, a delivered one after the grace")
    func delay() {
        #expect(AetherEngine.restartServedReseekDelay(.undelivered) == 0)
        #expect(AetherEngine.restartServedReseekDelay(.served) == AetherEngine.restartServedReseekGraceSeconds)
    }
}
