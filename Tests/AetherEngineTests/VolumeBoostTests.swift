import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.volumeBoost`: a gain over full scale's reach, held under it by the limiter.
@Suite("Volume boost")
struct VolumeBoostTests {

    @Test("requests are clamped to 100 to 300 %, and only over 100 % do anything")
    func clamping() {
        #expect(VolumeBoostProcessor.clampedGain(0.5) == 1)
        #expect(VolumeBoostProcessor.clampedGain(5) == 3)
        #expect(VolumeBoostProcessor.clampedGain(.nan) == 1)
        #expect(VolumeBoostProcessor.clampedGain(.infinity) == 1)
        #expect(!VolumeBoostProcessor.isActive(1))
        #expect(VolumeBoostProcessor.isActive(1.5))
        #expect(LoadOptions().volumeBoost == 1)
    }

    @Test("a quiet passage comes up by the whole gain")
    func quietGain() {
        let boost = VolumeBoostProcessor(gain: 2, sampleRate: 48_000)
        var left = [Float](repeating: 0.1, count: 480)
        var right = [Float](repeating: -0.2, count: 480)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                boost.process(planes: [l.baseAddress!, r.baseAddress!], frameCount: 480)
            }
        }
        #expect(abs(left[479] - 0.2) < 1e-6)
        #expect(abs(right[479] + 0.4) < 1e-6)
        #expect(boost.takeLimitedFrames().frames == 0)
    }

    @Test("what the gain pushes past full scale is held under it, in every layout the bridge hands over")
    func limited() {
        let frames = 4_800
        let tone = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 1_000 / 48_000) * 0.8) }

        let planar = VolumeBoostProcessor(gain: 3, sampleRate: 48_000)
        var a = tone, b = tone
        a.withUnsafeMutableBufferPointer { p in
            b.withUnsafeMutableBufferPointer { q in
                planar.process(planes: [p.baseAddress!, q.baseAddress!], frameCount: frames)
            }
        }
        #expect((a + b).allSatisfy { abs($0) <= PeakLimiter.threshold + 1e-6 })
        #expect(planar.takeLimitedFrames().frames > 0)

        // Six interleaved channels, as the FLAC bridge hands a 5.1 track over.
        let s32 = VolumeBoostProcessor(gain: 3, sampleRate: 48_000)
        var interleaved = [Int32](repeating: 0, count: frames * 6)
        for i in 0..<frames { for c in 0..<6 { interleaved[i * 6 + c] = Int32(Double(tone[i]) * 2_147_483_647) } }
        interleaved.withUnsafeMutableBufferPointer { s32.process(interleavedS32: $0.baseAddress!, channels: 6, frameCount: frames) }
        let ceiling = Int32(Double(PeakLimiter.threshold) * 2_147_483_647) + 256
        #expect(interleaved.allSatisfy { abs($0) <= ceiling })
        #expect(interleaved.contains { abs($0) > Int32(0.9 * 2_147_483_647) }, "the peaks reach the ceiling")

        let float = VolumeBoostProcessor(gain: 3, sampleRate: 48_000)
        var pcm = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { pcm[2 * i] = tone[i]; pcm[2 * i + 1] = tone[i] }
        pcm.withUnsafeMutableBufferPointer { float.process(interleavedFloat: $0.baseAddress!, channels: 2, frameCount: frames) }
        #expect(pcm.allSatisfy { abs($0) <= PeakLimiter.threshold + 1e-6 })
    }

    @Test("a boost takes the bridge, as dialogue boost does; off leaves the route alone")
    func routing() {
        let off = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: false)
        #expect(!off.audioIsProcessed)
        let on = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: false, volumeBoost: 2)
        #expect(on.audioIsProcessed)
        #expect(on.volumeBoost == 2)
        let clamped = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: false, volumeBoost: 9)
        #expect(clamped.volumeBoost == 3)
    }
}
