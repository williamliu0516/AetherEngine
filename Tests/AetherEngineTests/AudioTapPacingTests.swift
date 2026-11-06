import XCTest
@testable import AetherEngine

/// #95: pure pacing core for the loopback audio tap reader. The reader decodes the engine's own
/// fMP4 segments near the playhead; this decision function is the only piece that decides whether
/// to decode the next segment, idle, or re-anchor after the playhead moved away. It judges by the
/// stretch the reader holds (`readStart` to the last decoded end), not by the lead alone.
final class AudioTapPacingTests: XCTestCase {

    private func decide(_ start: Double?, _ last: Double?, _ playhead: Double) -> AudioTapPacing.Decision {
        AudioTapPacing.decide(readStart: start, lastDecodedEndPTS: last, playhead: playhead,
                              leadSeconds: 10, toleranceSeconds: 2)
    }

    func testFreshInstallDecodesImmediately() {
        XCTAssertEqual(decide(nil, nil, 0), .decodeNext)
        XCTAssertEqual(decide(nil, nil, 3512.4), .decodeNext)
    }

    func testWithinLeadKeepsDecoding() {
        XCTAssertEqual(decide(95, 105.0, 100.0), .decodeNext)   // 5 s ahead, lead is 10
        XCTAssertEqual(decide(95, 100.5, 100.0), .decodeNext)
    }

    func testAtLeadBoundarySleeps() {
        XCTAssertEqual(decide(95, 110.0, 100.0), .sleep)
        XCTAssertEqual(decide(95, 111.5, 100.0), .sleep)
    }

    func testFellBehindReanchors() {
        // Forward seek: playhead jumped past everything we decoded.
        XCTAssertEqual(decide(90, 100.0, 300.0), .reanchor)
        // Just past tolerance counts.
        XCTAssertEqual(decide(90, 97.9, 100.0), .reanchor)
    }

    func testBehindWithinToleranceStillDecodes() {
        XCTAssertEqual(decide(90, 98.5, 100.0), .decodeNext)
    }

    func testPlayheadJumpedBackReanchors() {
        // Backward seek: the playhead is before the stretch held.
        XCTAssertEqual(decide(290, 300.0, 100.0), .reanchor)
        XCTAssertEqual(decide(105, 112.5, 100.0), .reanchor)
    }

    // Decoding past lead + tolerance with the playhead inside the stretch is no seek (Zool's paused film,
    // 2026-11-05: re-anchored on the lead alone, the reader decoded the same seconds without end).
    func testDecodedPastTheLeadWithThePlayheadInsideSleeps() {
        XCTAssertEqual(decide(0, 18, 3), .sleep)
        XCTAssertEqual(decide(96, 118, 103.4), .sleep)
    }

    // Scrubbed back in steps of a second, none past the tolerance on its own: once the playhead is before the
    // stretch's start (less the tolerance) it re-anchors.
    func testScrubbingBackInSmallStepsReanchorsOnceBeforeTheStretch() {
        var steps: [AudioTapPacing.Decision] = []
        for playhead in stride(from: 99.0, through: 90, by: -1) { steps.append(decide(100, 114, playhead)) }
        XCTAssertEqual(steps.firstIndex(of: .reanchor), 2)     // at 97 s, 3 s before the stretch
    }

    func testABigSeekBackWhileStillShortOfTheLeadReanchors() {
        XCTAssertEqual(decide(100, 102, 20), .reanchor)
    }
}
