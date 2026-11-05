import Foundation
import Testing
@testable import AetherEngine

/// A second track's lines inside the native renditions (`setNativeSubtitleCompanion`), for a host whose overlay does
/// not show over the picture (Vision Pro's expanded player): the rendition served carries what the host combines.
@Suite("Native subtitle companion", .offCooperativePool)
struct NativeSubtitleCompanionTests {
    private func store(_ cues: [(Double, Double, String)], finished: Bool = true) -> NativeSubtitleCueStore {
        let store = NativeSubtitleCueStore()
        Self.append(cues, to: store)
        if finished { store.markFinished() }
        return store
    }

    private static func append(_ cues: [(Double, Double, String)], to store: NativeSubtitleCueStore) {
        store.appendCues(cues.enumerated().map { i, cue in
            SubtitleCue(id: Int(cue.0 * 1000) + i, startTime: cue.0, endTime: cue.1, body: .text(cue.2))
        })
    }

    private func provider(_ stores: [NativeSubtitleCueStore]) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(),
            segments: [HLSVideoEngine.Segment(startPts: 0, endPts: 4000, startSeconds: 0, durationSeconds: 4.0),
                       HLSVideoEngine.Segment(startPts: 4000, endPts: 8000, startSeconds: 4.0, durationSeconds: 4.0)],
            codecsString: "avc1.640028", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0,
            hdcpLevel: nil, sourceBitrate: 1_000_000,
            nativeSubtitleStores: stores, nativeSubtitleLanguages: ["chi", "eng"],
            stripASSMarkupInVTT: true
        )
    }

    /// Joins each second cue to the first it overlaps; a second cue overlapping none is served alone.
    private static let join: NativeSubtitleCombine = { first, second in
        var out = first.map { cue in
            let with = second.filter { $0.end > cue.start && $0.start < cue.end }.map(\.text)
            return (cue.start, cue.end, ([cue.text] + with).joined(separator: "\n"))
        }
        out += second.filter { s in !first.contains { $0.end > s.start && $0.start < s.end } }
        return out
    }

    @Test("The rendition carries the companion's lines as the host combines them, plain, the companion's own as it is")
    func renditionCarriesTheSecondLine() throws {
        let chinese = store([(1.0, 3.0, "7,0,Default,,0,0,0,,{\\i1}你好{\\i0}"), (5.0, 6.0, "再见")])
        let english = store([(1.1, 2.9, "Hello"), (3.5, 3.8, "Hm."), (5.0, 6.0, "Bye")])
        let provider = provider([chinese, english])
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)?.contains("你好\nHello") == false)
        provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
        let first = try #require(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0))
        #expect(first.contains("你好\nHello"))
        #expect(first.contains("Hm."), "a line the first track does not have shows alone")
        #expect(!first.contains("再见"), "cut back to the segment's window")
        #expect(!first.contains("{\\i1}"), "both sides plain")
        let second = try #require(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 1))
        #expect(second.contains("再见\nBye"))
        let own = try #require(provider.nativeSubtitleVTT(ordinal: 1, segmentIndex: 0))
        #expect(own.contains("Hello") && !own.contains("你好"))
        provider.setNativeSubtitleCompanion(ordinal: nil, combine: nil)
        let off = try #require(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0))
        #expect(off.contains("你好") && !off.contains("Hello"))
    }

    /// A first cue crossing the segments' edge is served the same in both, its second line looked for around
    /// either window.
    @Test("A cue across two segments carries the same second line in both")
    func aCueAcrossTheEdgeIsPairedAlikeInBoth() throws {
        let provider = provider([store([(3.0, 5.0, "跨过")]), store([(4.5, 5.0, "Across")])])
        provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)?.contains("跨过\nAcross") == true)
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 1)?.contains("跨过\nAcross") == true)
    }

    /// A first cue that runs through several windows (0-30 s) and a companion cue near its end (29-30 s) are
    /// served together in every window, however long the cue (Codex's review, M1: a fixed margin missed it).
    @Test("A long cue carries its second line in every window it crosses")
    func aLongCueIsPairedInEveryWindow() throws {
        let provider = provider([store([(0.0, 30.0, "长")]), store([(29.0, 30.0, "Long")])])
        provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)?.contains("长\nLong") == true)
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 1)?.contains("长\nLong") == true)
    }

    /// A companion the reader has given nothing (an empty track, a reader not started) is not waited on: the
    /// window is served at once (H1: every request on a connection AVPlayer shares with video waited 3 s).
    @Test("An empty companion is not waited on")
    func anEmptyCompanionIsNotWaitedOn() {
        let provider = provider([store([(1.0, 2.0, "一")]), store([], finished: false)])
        provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
        let began = Date()
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)?.contains("一") == true)
        #expect(Date().timeIntervalSince(began) < 1)
    }

    /// The timeline moving while a window is read (a restart shifting a store): read again once, then paired;
    /// still moving, the window goes out with the first line alone.
    @Test("A window read across a timeline change is read again, or served alone")
    func aWindowReadAcrossAChangeIsReadAgainOrServedAlone() {
        final class Moves: @unchecked Sendable {
            let lock = NSLock()
            var left: Int
            init(_ left: Int) { self.left = left }
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; left -= 1; return left >= 0 }
        }
        // The rendition's own read takes the first move; the companion's first read meets the second.
        for (moves, paired) in [(2, true), (1_000, false)] {
            let chinese = store([(1.0, 2.0, "一")]), english = store([(1.0, 2.0, "One")])
            let left = Moves(moves)
            // Reading the first store moves the second's shift (to where it is, so its cues stay put).
            chinese.setTextTransform { text in
                if left.take() { english.setShiftSeconds(0) }
                return text
            }
            let provider = provider([chinese, english])
            provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
            let vtt = provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)
            #expect(vtt?.contains("一\nOne") == paired, "\(moves) moves: \(vtt ?? "nil")")
            #expect(vtt?.contains("一") == true)
        }
    }

    /// Two stores read on different axes (a restart moved one's shift and not yet the other's) are not paired:
    /// the window is served alone (H4).
    @Test("Stores on two axes are served alone")
    func storesOnTwoAxesAreServedAlone() {
        // Read on its own shift, 6-7 s lands on 1-2 s, beside 一: on one axis they would not meet.
        let english = store([(6.0, 7.0, "One")])
        english.setShiftSeconds(5)
        let provider = provider([store([(1.0, 2.0, "一")]), english])
        provider.setNativeSubtitleCompanion(ordinal: 1, combine: Self.join)
        let vtt = provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)
        #expect(vtt?.contains("一") == true && vtt?.contains("One") == false)
    }

    /// An ordinal past the renditions is no companion.
    @Test("A companion past the renditions serves the rendition as it is")
    func aCompanionPastTheRenditionsIsNone() {
        let provider = provider([store([(1.0, 2.0, "一")])])
        provider.setNativeSubtitleCompanion(ordinal: 3, combine: Self.join)
        #expect(provider.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)?.contains("一") == true)
    }
}
