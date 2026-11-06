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

    /// By the stretch the reader holds, `readStart` (where it anchored: the start of the first segment it decoded
    /// there) to `lastDecodedEndPTS`: the playhead outside it, by more than the tolerance either way, is a seek and
    /// re-anchors at the playhead; inside it, the reader decodes on while it is less than `leadSeconds` ahead, else
    /// sleeps. It judged by the lead alone, and went back to the playhead's segment whenever it stood more than lead +
    /// tolerance ahead, which decoding one segment routinely carries it to (6 s segments from a paused playhead at 3 s
    /// end 15 s ahead): it decoded the same seconds again without end while paused, and over and over while playing
    /// (Zool's paused film, 2026-11-05: the tap's thread at 165 ms a second, its consumer classifying the same audio at
    /// 888 ms). A playhead moved back in any number of small steps, or by one large one at any point, is outside the
    /// stretch once it is before its start. Nothing decoded yet (`lastDecodedEndPTS` or `readStart` nil): decode.
    static func decide(readStart: Double?, lastDecodedEndPTS: Double?, playhead: Double,
                       leadSeconds: Double, toleranceSeconds: Double) -> Decision {
        guard let last = lastDecodedEndPTS, let start = readStart else { return .decodeNext }
        if playhead < start - toleranceSeconds || playhead > last + toleranceSeconds { return .reanchor }
        return last - playhead < leadSeconds ? .decodeNext : .sleep
    }
}
