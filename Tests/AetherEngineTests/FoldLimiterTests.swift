import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Folding 7.1 into the E-AC-3 bridge's 5.1 adds each back channel to its side channel at full weight, and
/// libswresample does not normalize a float rematrix: 环太平洋's climax peaked at 1.43 in the side channels, and
/// E-AC-3 carried the overs to the decoder (Zool on a MacBook, Diagnostics 81: crackle). The bridge then runs the peak
/// limiter at unity.
@Suite("Fold limiter")
struct FoldLimiterTests {
    @Test("the limiter runs where the E-AC-3 bridge folds channels, and nowhere else")
    func onlyAFoldIntoEAC3() {
        #expect(AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 8, encoderChannels: 6,
                                             dialogueBoost: false))
        #expect(!AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 6, encoderChannels: 6,
                                              dialogueBoost: false))
        #expect(!AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_FLAC, sourceChannels: 8, encoderChannels: 8,
                                              dialogueBoost: false))
        #expect(!AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 8, encoderChannels: 2,
                                              dialogueBoost: true))
    }

    @Test("at unity the stage holds a fold's 1.43 under full scale and leaves ordinary levels alone")
    func unityHoldsTheFoldsPeaks() {
        let stage = VolumeBoostProcessor(gain: 1, sampleRate: 48_000)
        let frames = 4_800
        let side = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let centre = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { side.deallocate(); centre.deallocate() }
        for i in 0..<frames {
            let wave = Float(sin(Double(i) * 2 * .pi * 440 / 48_000))
            side[i] = 1.43 * wave
            centre[i] = 0.5 * wave
        }
        stage.process(planes: [side, centre], frameCount: frames)
        #expect((0..<frames).allSatisfy { abs(side[$0]) <= 1 })
        // The other channel is held too while the limiter works (one gain for all, no image shift), but a passage
        // under full scale on its own comes through at unity.
        let quiet = VolumeBoostProcessor(gain: 1, sampleRate: 48_000)
        let alone = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { alone.deallocate() }
        for i in 0..<frames { alone[i] = 0.5 * Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) }
        let before = (0..<frames).map { alone[$0] }
        quiet.process(planes: [alone], frameCount: frames)
        #expect((0..<frames).allSatisfy { abs(alone[$0] - before[$0]) < 1e-6 })
    }
}
