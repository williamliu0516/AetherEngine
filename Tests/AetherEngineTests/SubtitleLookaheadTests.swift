import Testing
import Foundation
@testable import AetherEngine

/// `setSubtitleLookahead`: the forward prefetcher (#151), a second read of the source, runs only as far as the host
/// reads cues ahead, and a bitmap cue's end is taken only across ground a harvest has read.
@Suite("Subtitle lookahead")
struct SubtitleLookaheadTests {

    @Test("the prefetch lead: the drain window by default, none for a zero lookahead, the OCR's window while armed")
    func prefetchLead() {
        let drain = AetherEngine.subtitleDrainLeadSeconds + AetherEngine.subtitleForwardPrefetchLeadMarginSeconds
        let margin = AetherEngine.subtitleForwardPrefetchLeadMarginSeconds
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: false, lookahead: nil) == drain)
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: false, lookahead: 0) == nil)
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: false, lookahead: 8) == 8 + margin)
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: false, lookahead: 600) == drain,
                "past the drain window nothing decodes the packets, so nothing reads for them")
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: true, lookahead: 0)
                == AetherEngine.subtitleOCRPrefetchLeadSeconds)
        #expect(AetherEngine.subtitleForwardPrefetchLead(ocrArmed: true, lookahead: nil)
                == AetherEngine.subtitleOCRPrefetchLeadSeconds)
    }

    @MainActor
    @Test("the lookahead is kept as asked, negative and non-finite values as zero, nil as the default")
    func lookaheadValues() throws {
        let engine = try AetherEngine()
        #expect(engine.subtitleLookaheadSeconds == nil)
        engine.setSubtitleLookahead(0)
        #expect(engine.subtitleLookaheadSeconds == 0)
        engine.setSubtitleLookahead(12.5)
        #expect(engine.subtitleLookaheadSeconds == 12.5)
        engine.setSubtitleLookahead(-3)
        #expect(engine.subtitleLookaheadSeconds == 0)
        engine.setSubtitleLookahead(.nan)
        #expect(engine.subtitleLookaheadSeconds == 0)
        engine.setSubtitleLookahead(nil)
        #expect(engine.subtitleLookaheadSeconds == nil)
    }

    @Test("a cue's end: the next packet within the horizon, and with a lookahead only across read ground")
    func derivedEnd() {
        let readTo100: (Double, Double) -> Bool = { _, through in through <= 100 }
        #expect(AetherEngine.derivedCueEnd(start: 50, nextPacket: 53, horizon: 135, requireRead: false,
                                          hasRead: readTo100) == 53)
        #expect(AetherEngine.derivedCueEnd(start: 50, nextPacket: nil, horizon: 135, requireRead: false,
                                          hasRead: readTo100) == nil)
        #expect(AetherEngine.derivedCueEnd(start: 50, nextPacket: 140, horizon: 135, requireRead: false,
                                          hasRead: readTo100) == nil, "past the horizon")
        // A packet left from an earlier visit beyond a hole: inside the horizon, but nobody read up to it.
        #expect(AetherEngine.derivedCueEnd(start: 95, nextPacket: 120, horizon: 135, requireRead: true,
                                          hasRead: readTo100) == nil)
        #expect(AetherEngine.derivedCueEnd(start: 95, nextPacket: 98, horizon: 135, requireRead: true,
                                          hasRead: readTo100) == 98)
        #expect(AetherEngine.derivedCueEnd(start: 95, nextPacket: 120, horizon: 135, requireRead: false,
                                          hasRead: readTo100) == 120, "the default keeps the horizon rule alone")
    }

    @Test("the pump's progress notes make the stretch it read provable, and nothing past it")
    func pumpProgressCoverage() {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.pump, at: 40)
        for t in stride(from: 40.0, through: 90, by: 0.5) { store.noteHarvestProgress(.pump, through: t) }
        #expect(store.hasReadSpan(from: 45, through: 89))
        #expect(!store.hasReadSpan(from: 85, through: 120))
    }
}
