import Foundation

/// Zool's fork: the host's dialogue boost and volume boost (`LoadOptions.dialogueBoost`, `LoadOptions.volumeBoost`) as
/// upstream's `AudioShaping` (AE#923). The fork carried processors of its own for both (7.37.0-zool.6 and .9); on
/// 7.54.0 the user picked shaping instead (2026-11-02, "A"), so a host keeps the two options and the engine keeps one
/// audio-shaping path. Setting either option writes `LoadOptions.audioShaping` through `shaping(dialogue:volume:)`.
///
/// Like any active shaping, a boost needs PCM: a stream-copied track is bridged while it is on, trading Atmos and
/// bitstream passthrough for it, so a host sets it only for a route it decodes for (built-in speakers, headphones),
/// never HDMI or AirPlay, where the receiver's volume is the control.
public enum AudioBoost {
    /// The volume boost's top: 3 (300 %, +9.5 dB). 1 is off; values outside are clamped.
    public static let maxVolume: Double = 3

    /// The dialogue lift: the centre raised wherever it lands in the stereo fold; on a stereo source, the dialogue
    /// libavfilter's `dialoguenhance` extracts.
    public static let dialogueGainDB: Double = 6

    /// Dialogue boost's dynamics, for speech at low volume: everything over -36 dBFS compressed 3:1 and lifted 14 dB,
    /// as the fork's own processor did, then the shaping's -1 dBFS limiter.
    public static let dialogueCompressor = AudioShaping.Compressor(thresholdDB: -36, ratio: 3, makeupGainDB: 14,
                                                                   attackMilliseconds: 5, releaseMilliseconds: 250,
                                                                   kneeDB: 6)

    /// The shaping for dialogue boost on or off and a volume boost of `volume`: nothing when both are off. Dialogue
    /// boost folds to two channels with the dialogue lifted and compressed; the volume's gain is added to the
    /// compressor's makeup (a plain compressor at 1:1 when only the volume is boosted), and the shaping's limiter holds
    /// the result under full scale.
    public static func shaping(dialogue: Bool, volume: Double) -> AudioShaping {
        let gain = volume.isFinite ? min(max(volume, 1), maxVolume) : 1
        let gainDB = 20 * log10(gain)
        if dialogue {
            var compressor = dialogueCompressor
            compressor.makeupGainDB += gainDB
            return AudioShaping(maxChannels: 2, dialogueGainDB: dialogueGainDB, compressor: compressor)
        }
        guard gain > 1 else { return AudioShaping() }
        // A gain alone: a compressor that never compresses (1:1), its makeup the gain.
        return AudioShaping(compressor: AudioShaping.Compressor(thresholdDB: 0, ratio: 1, makeupGainDB: gainDB,
                                                                kneeDB: 0))
    }
}
