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
