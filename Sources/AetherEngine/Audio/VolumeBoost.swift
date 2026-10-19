import Foundation

/// `LoadOptions.volumeBoost`'s processing: a gain over the system's own maximum, for a film that stays too quiet
/// on a phone's or a tablet's speakers, or on headphones, with the volume all the way up.
///
/// One linear gain for every channel, then the engine's `PeakLimiter`, so what the gain pushes past full scale is
/// held at −0.18 dBFS instead of clipping. Quiet and ordinary passages come up by the whole gain; the loud ones
/// come up only as far as full scale allows, which is the limiter working (its counters say how often). No
/// lookahead, like the limiter itself: a delay here would shift the audio against the video.
final class VolumeBoostProcessor {

    /// The gains a host can ask for: 100 % (off) to 300 % (+9.5 dB).
    static let gainRange: ClosedRange<Double> = 1 ... 3

    /// `gain` clamped into `gainRange`, and a non-finite value read as off.
    static func clampedGain(_ gain: Double) -> Double {
        gain.isFinite ? min(max(gain, gainRange.lowerBound), gainRange.upperBound) : 1
    }

    /// Whether a requested gain does anything (the bridge is taken only then).
    static func isActive(_ gain: Double) -> Bool { clampedGain(gain) > 1.001 }

    let gain: Float
    private var limiter: PeakLimiter
    /// Planes for the interleaved formats: `channels` runs of `capacity` floats.
    private var storage: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var planes: [UnsafeMutablePointer<Float>] = []

    init(gain: Double, sampleRate: Int) {
        self.gain = Float(Self.clampedGain(gain))
        limiter = PeakLimiter(sampleRate: max(sampleRate, 8_000))
    }

    deinit { storage?.deallocate() }

    /// Process float planes in place (the E-AC-3 bridge's PCM).
    func process(planes pointers: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard frameCount > 0, !pointers.isEmpty else { return }
        for plane in pointers {
            for i in 0..<frameCount { plane[i] *= gain }
        }
        limiter.process(pointers, frameCount: frameCount)
    }

    /// Process interleaved S32 in place (the FLAC bridge's PCM, 24 bits in the top of 32).
    func process(interleavedS32 samples: UnsafeMutablePointer<Int32>, channels: Int, frameCount: Int) {
        guard frameCount > 0, channels > 0 else { return }
        ensureCapacity(channels: channels, frames: frameCount)
        let scale: Float = 1 / 2_147_483_648
        for i in 0..<frameCount {
            for c in 0..<channels { planes[c][i] = Float(samples[i * channels + c]) * scale * gain }
        }
        limiter.process(planes, frameCount: frameCount)
        for i in 0..<frameCount {
            for c in 0..<channels { samples[i * channels + c] = Self.s32(planes[c][i]) }
        }
    }

    /// Process interleaved float in place (the software path's PCM).
    func process(interleavedFloat samples: UnsafeMutablePointer<Float>, channels: Int, frameCount: Int) {
        guard frameCount > 0, channels > 0 else { return }
        ensureCapacity(channels: channels, frames: frameCount)
        for i in 0..<frameCount {
            for c in 0..<channels { planes[c][i] = samples[i * channels + c] * gain }
        }
        limiter.process(planes, frameCount: frameCount)
        for i in 0..<frameCount {
            for c in 0..<channels { samples[i * channels + c] = planes[c][i] }
        }
    }

    /// Forget the limiter's envelope (a seek or restart).
    func reset() { limiter.reset() }

    /// Frames the limiter reduced and its deepest reduction since the last call.
    func takeLimitedFrames() -> (frames: Int, deepestDB: Float) { limiter.takeLimitedFrames() }

    private func ensureCapacity(channels: Int, frames: Int) {
        guard planes.count != channels || capacity < frames else { return }
        storage?.deallocate()
        capacity = max(frames, capacity)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: channels * capacity)
        storage = buffer
        planes = (0..<channels).map { buffer + $0 * capacity }
    }

    private static func s32(_ x: Float) -> Int32 {
        let clamped = min(max(x, -1), 1)
        return Int32(clamping: Int64((Double(clamped) * 2_147_483_647).rounded()))
    }
}
