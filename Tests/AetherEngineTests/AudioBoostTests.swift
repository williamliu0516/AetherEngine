import Foundation
import Testing
@testable import AetherEngine

/// Zool's fork: a host's dialogue boost and volume boost written into `audioShaping` (`AudioBoost`), the user's pick A
/// of 2026-11-02 over the fork's own processors.
struct AudioBoostTests {

    @Test("both off shape nothing, and the session is left as it was")
    func offShapesNothing() {
        let off = AudioBoost.shaping(dialogue: false, volume: 1)
        #expect(off == AudioShaping())
        #expect(!off.isActive)
        let below = AudioBoost.shaping(dialogue: false, volume: 0.5)
        let broken = AudioBoost.shaping(dialogue: false, volume: .nan)
        #expect(below == AudioShaping())
        #expect(broken == AudioShaping())
    }

    @Test("a volume boost is a 1:1 compressor whose makeup is the gain, up to 300 %")
    func volumeIsAGain() throws {
        let double = AudioBoost.shaping(dialogue: false, volume: 2)
        let compressor = try #require(double.compressor)
        #expect(double.maxChannels == nil)
        #expect(double.dialogueGainDB == 0)
        #expect(compressor.ratio == 1)
        #expect(abs(compressor.makeupGainDB - 6.0206) < 0.001)
        #expect(double.isActive)
        let past = AudioBoost.shaping(dialogue: false, volume: 5)
        let top = try #require(past.compressor)
        #expect(abs(top.makeupGainDB - 9.5424) < 0.001)
    }

    @Test("dialogue boost folds to two channels with the dialogue lifted and compressed; a volume boost adds its gain")
    func dialogueWithVolume() throws {
        let dialogue = AudioBoost.shaping(dialogue: true, volume: 1)
        let compressor = try #require(dialogue.compressor)
        #expect(dialogue.maxChannels == 2)
        #expect(dialogue.dialogueGainDB == AudioBoost.dialogueGainDB)
        #expect(compressor.thresholdDB == -36)
        #expect(compressor.ratio == 3)
        #expect(compressor.makeupGainDB == 14)
        let both = AudioBoost.shaping(dialogue: true, volume: 3)
        let louder = try #require(both.compressor)
        #expect(abs(louder.makeupGainDB - (14 + 9.5424)) < 0.001)
        // Inside what the compressor carries (24 dB of makeup), so nothing is clamped away.
        let kept = try #require(both.clamped.compressor)
        #expect(kept.makeupGainDB == louder.makeupGainDB)
    }

    @Test("setting either option writes the load's audioShaping, and turning both off clears it")
    func loadOptionsFollow() {
        var options = LoadOptions()
        options.volumeBoost = 2
        let volume = AudioBoost.shaping(dialogue: false, volume: 2)
        #expect(options.audioShaping == volume)
        options.dialogueBoost = true
        let both = AudioBoost.shaping(dialogue: true, volume: 2)
        #expect(options.audioShaping == both)
        options.dialogueBoost = false
        options.volumeBoost = 1
        #expect(options.audioShaping == AudioShaping())
    }
}
