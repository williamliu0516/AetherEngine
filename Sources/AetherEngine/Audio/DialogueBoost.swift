import Foundation
import AetherLibavutil
import AetherLibswresample

/// `LoadOptions.dialogueBoost`'s processing: speech forward, the loud parts down, for a film heard on a
/// phone's speakers or headphones at low volume.
///
/// A 5.1 or 7.1 mix keeps its dialogue in the centre channel, and the standard fold to two channels
/// (ITU-R BS.775: centre and surrounds at −3 dB) leaves it under the music and effects that six speakers
/// would have spread around the room. Three stages fix that, in the order a broadcaster's night mode uses
/// them:
///
/// 1. The fold itself favours the centre: `swresample`'s matrix with the centre at +3 dB and the surrounds
///    at −6 dB (`centerMixLevel`, `surroundMixLevel`), LFE left out. A source of two channels or fewer has
///    no centre to favour, so its mid (L+R, where a mix pans dialogue) is raised against its side instead.
/// 2. A presence lift: +3 dB around 2.5 kHz, where consonants carry intelligibility.
/// 3. A compressor with make-up gain: everything over −36 dBFS is reduced 3:1, then the whole raised by
///    14 dB, so dialogue at a film's usual level comes up about 12 dB and an explosion goes down about 3 dB. The
///    engine's `PeakLimiter` keeps what is left under full scale.
///
/// Linked stereo throughout (one gain for both channels), so nothing moves across the image. No lookahead:
/// the bridge produces ahead of playback, but a delay here would still shift the audio against the video.
/// The figures are a starting point tuned by ear on a phone's speakers; `Tuning` names each one.
final class DialogueBoostProcessor {

    enum Tuning {
        /// `swresample`'s `center_mix_level`: +3 dB, against the −3 dB of the standard fold.
        static let centerMixLevel = 1.4142
        /// `swresample`'s `surround_mix_level` (sides and backs alike): −6 dB.
        static let surroundMixLevel = 0.5
        /// `swresample`'s `lfe_mix_level`: the LFE stays out of a fold for small speakers.
        static let lfeMixLevel = 0.0
        /// A two-channel source: mid +1.5 dB, side −1.5 dB.
        static let midGain: Float = 1.1885
        static let sideGain: Float = 0.8414
        static let presenceHz = 2500.0
        static let presenceGainDB = 3.0
        static let presenceQ = 0.9
        static let thresholdDB: Float = -36
        static let ratio: Float = 3
        static let kneeDB: Float = 6
        static let makeupDB: Float = 14
        /// The level detector's time constant (mean square of both channels).
        static let detectorSeconds = 0.010
        static let attackSeconds = 0.010
        static let releaseSeconds = 0.200
    }

    private let stereoSource: Bool
    private var presenceLeft: Biquad
    private var presenceRight: Biquad
    private let detectorCoefficient: Float
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    /// Mean square of the two channels, smoothed by `detectorCoefficient`.
    private var power: Float = 0
    /// The compressor's current gain in dB, before make-up.
    private var gainDB: Float = 0
    private var limiter: PeakLimiter
    private var left: [Float] = []
    private var right: [Float] = []

    /// `stereoSource`: the source had two channels or fewer, so the mid/side stage runs in place of the
    /// centre-weighted fold.
    init(sampleRate: Int, stereoSource: Bool) {
        self.stereoSource = stereoSource
        let rate = Double(max(sampleRate, 8_000))
        let presence = Biquad.peaking(
            frequency: min(Tuning.presenceHz, rate * 0.45), q: Tuning.presenceQ,
            gainDB: Tuning.presenceGainDB, sampleRate: rate)
        presenceLeft = presence
        presenceRight = presence
        detectorCoefficient = Float(exp(-1 / (Tuning.detectorSeconds * rate)))
        attackCoefficient = Float(exp(-1 / (Tuning.attackSeconds * rate)))
        releaseCoefficient = Float(exp(-1 / (Tuning.releaseSeconds * rate)))
        limiter = PeakLimiter(sampleRate: Int(rate))
    }

    /// Process interleaved two-channel S32 in place (the FLAC bridge's PCM, 24 bits in the top of 32).
    func process(interleavedS32 samples: UnsafeMutablePointer<Int32>, frameCount: Int) {
        guard frameCount > 0 else { return }
        ensureCapacity(frameCount)
        let scale: Float = 1 / 2_147_483_648
        for i in 0..<frameCount {
            left[i] = Float(samples[2 * i]) * scale
            right[i] = Float(samples[2 * i + 1]) * scale
        }
        run(frameCount)
        for i in 0..<frameCount {
            samples[2 * i] = Self.s32(left[i])
            samples[2 * i + 1] = Self.s32(right[i])
        }
    }

    /// Process interleaved two-channel float in place (the software path's PCM).
    func process(interleavedFloat samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        ensureCapacity(frameCount)
        for i in 0..<frameCount { left[i] = samples[2 * i]; right[i] = samples[2 * i + 1] }
        run(frameCount)
        for i in 0..<frameCount { samples[2 * i] = left[i]; samples[2 * i + 1] = right[i] }
    }

    /// Process two float planes in place (the E-AC-3 bridge's PCM, when the build has no FLAC encoder).
    func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        ensureCapacity(frameCount)
        for i in 0..<frameCount { left[i] = l[i]; right[i] = r[i] }
        run(frameCount)
        for i in 0..<frameCount { l[i] = left[i]; r[i] = right[i] }
    }

    /// The centre-weighted fold, set on a resampler before `swr_init`. The matrix is normalised so no
    /// output channel's coefficients sum past 1 (`rematrix_maxval`): swresample does that by itself only
    /// for integer output, so without it the software path (float) played the fold 9 dB hotter than the
    /// bridge (S32) and the compressor saw different levels on the two. The make-up gain brings it back.
    static func applyFold(to swr: OpaquePointer) {
        let ctx = UnsafeMutableRawPointer(swr)
        av_opt_set_double(ctx, "center_mix_level", Tuning.centerMixLevel, 0)
        av_opt_set_double(ctx, "surround_mix_level", Tuning.surroundMixLevel, 0)
        av_opt_set_double(ctx, "lfe_mix_level", Tuning.lfeMixLevel, 0)
        av_opt_set_double(ctx, "rematrix_maxval", 1.0, 0)
    }

    /// Forget the filters' and the compressor's state (a seek or restart).
    func reset() {
        presenceLeft.reset()
        presenceRight.reset()
        power = 0
        gainDB = 0
        limiter.reset()
    }

    /// The compressor's static curve: the gain in dB (before make-up) for a level in dBFS, soft knee.
    static func compressorGainDB(levelDB x: Float) -> Float {
        let t = Tuning.thresholdDB, r = Tuning.ratio, w = Tuning.kneeDB
        let over = x - t
        if 2 * over <= -w { return 0 }
        if 2 * over >= w { return over / r - over }
        let k = over + w / 2
        return (1 / r - 1) * k * k / (2 * w)
    }

    private func run(_ n: Int) {
        let makeup = Self.linear(Tuning.makeupDB)
        for i in 0..<n {
            var l = left[i], r = right[i]
            if stereoSource {
                let mid = (l + r) * 0.5 * Tuning.midGain
                let side = (l - r) * 0.5 * Tuning.sideGain
                l = mid + side
                r = mid - side
            }
            l = presenceLeft.process(l)
            r = presenceRight.process(r)
            let square = (l * l + r * r) * 0.5
            power = detectorCoefficient * power + (1 - detectorCoefficient) * square
            let target = Self.compressorGainDB(levelDB: 10 * log10(max(power, 1e-12)))
            let coefficient = target < gainDB ? attackCoefficient : releaseCoefficient
            gainDB = coefficient * gainDB + (1 - coefficient) * target
            let gain = Self.linear(gainDB) * makeup
            left[i] = l * gain
            right[i] = r * gain
        }
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                limiter.process([lp.baseAddress!, rp.baseAddress!], frameCount: n)
            }
        }
    }

    private func ensureCapacity(_ n: Int) {
        if left.count < n {
            left = [Float](repeating: 0, count: n)
            right = [Float](repeating: 0, count: n)
        }
    }

    private static func linear(_ db: Float) -> Float { powf(10, db / 20) }

    private static func s32(_ x: Float) -> Int32 {
        let clamped = min(max(x, -1), 1)
        return Int32(clamping: Int64((Double(clamped) * 2_147_483_647).rounded()))
    }
}

/// A second-order section (RBJ cookbook), direct form I.
struct Biquad {
    private var b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: Float((1 + alpha * a) / a0), b1: Float(-2 * cos(w) / a0), b2: Float((1 - alpha * a) / a0),
            a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha / a) / a0))
    }

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
}
