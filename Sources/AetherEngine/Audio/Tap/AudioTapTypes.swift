import Foundation
import AVFAudio

/// One decoded tap buffer (#95). Handed to exactly one consumer via `AsyncStream`; the engine
/// never touches `buffer` after yielding it, which is the invariant behind `@unchecked Sendable`.
public struct AudioTapBuffer: @unchecked Sendable {
    /// Mono Float32 48 kHz PCM (see `AetherEngine.audioTapFormat`).
    public let buffer: AVAudioPCMBuffer
    /// Source-PTS seconds of the first sample, same axis as `AetherEngine.sourceTime`.
    public let sourceTime: Double
    /// True when this buffer does not abut the previous one (seek, gap, drop, track switch).
    /// Non-discontinuity buffers are guaranteed strictly increasing and non-overlapping on
    /// `sourceTime` (AudioTapMonotonicFilter trims sub-`overlapTrimThreshold` seam overlaps),
    /// which SpeechAnalyzer's input timeline requires.
    public let discontinuity: Bool
}

public extension AetherEngine {
    /// The fixed output format of the audio tap. Computed per call because `AVAudioFormat`
    /// is not Sendable and cannot be a stored static under strict concurrency.
    nonisolated static var audioTapFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }
}

enum AudioTapDefaults {
    static let leadSeconds: Double = 10
    static let toleranceSeconds: Double = 2
    static let minSamplesPerChunk = 4800   // 100 ms at 48 kHz
    static let sampleRate: Double = 48_000
    /// Max backward PTS overlap (seconds) the monotonic gate trims silently. Segment-seam
    /// decoder priming is tens of ms; a larger backward jump is a real seek and is passed
    /// through as a discontinuity instead.
    static let overlapTrimThreshold: Double = 0.25
}

/// Pure pacing decision for the loopback reader (#95). Playlist-axis seconds on both inputs.
enum AudioTapPacing {
    enum Decision: Equatable {
        case decodeNext   // decode the segment after the last decoded one
        case sleep        // full lead decoded; idle and recheck
        case reanchor     // playhead moved away; jump to the playhead's segment
    }

    /// `previousPlayhead`: the playhead at the reader's last step. Decoded further ahead than lead + tolerance is a
    /// backward seek only when the playhead moved back since then: decoding one segment routinely carries the reader
    /// past lead + tolerance (6 s segments from a paused playhead at 3 s end 15 s ahead), and re-anchoring on that
    /// alone sent it back to the playhead's segment to decode the same seconds again, without end while paused and
    /// again and again while playing (Zool's paused film: the tap's thread at 165 ms a second and its consumer
    /// classifying the same audio at 888 ms, 2026-11-05). Nil: unknown, any lead past the tolerance counts as a seek,
    /// as before.
    static func decide(lastDecodedEndPTS: Double?, playhead: Double, previousPlayhead: Double? = nil,
                       leadSeconds: Double, toleranceSeconds: Double) -> Decision {
        guard let last = lastDecodedEndPTS else { return .decodeNext }
        if last < playhead - toleranceSeconds { return .reanchor }
        if last - playhead > leadSeconds + toleranceSeconds {
            let movedBack = previousPlayhead.map { playhead < $0 - toleranceSeconds } ?? true
            return movedBack ? .reanchor : .sleep
        }
        if last - playhead >= leadSeconds { return .sleep }
        return .decodeNext
    }
}
