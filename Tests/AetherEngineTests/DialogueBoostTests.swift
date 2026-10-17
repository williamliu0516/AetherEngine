import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample
@testable import AetherEngine

/// `LoadOptions.dialogueBoost`: speech forward and the loud parts down when a film is folded to two
/// channels for a phone's speakers or headphones (see `DialogueBoostProcessor`).
@Suite("Dialogue boost", .serialized)
struct DialogueBoostTests {

    // MARK: - The compressor's curve

    @Test("the curve leaves quiet audio alone, reduces 3:1 above the knee and is continuous across it")
    func compressorCurve() {
        #expect(DialogueBoostProcessor.compressorGainDB(levelDB: -50) == 0)
        #expect(abs(DialogueBoostProcessor.compressorGainDB(levelDB: -33) - -2) < 0.001)
        #expect(abs(DialogueBoostProcessor.compressorGainDB(levelDB: -10) - -17.333) < 0.01)
        let t = DialogueBoostProcessor.Tuning.thresholdDB, w = DialogueBoostProcessor.Tuning.kneeDB
        for edge in [t - w / 2, t + w / 2] {
            let below = DialogueBoostProcessor.compressorGainDB(levelDB: edge - 0.001)
            let above = DialogueBoostProcessor.compressorGainDB(levelDB: edge + 0.001)
            #expect(abs(below - above) < 0.01)
        }
    }

    // MARK: - The processor

    /// RMS in dBFS of the last half of a buffer, where the compressor has settled.
    private func settledRMS(_ x: [Float]) -> Float {
        let tail = x[(x.count / 2)...]
        let ms = tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)
        return 10 * log10(max(ms, 1e-12))
    }

    /// Two seconds of a 1 kHz tone in both channels through a processor, as the software path hands it.
    private func process(amplitude: Float, stereoSource: Bool = false,
                         side: Bool = false) -> (inDB: Float, outLeft: [Float], peak: Float) {
        let rate = 48_000, frames = rate * 2
        var interleaved = [Float](repeating: 0, count: frames * 2)
        var input = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let v = amplitude * sinf(2 * .pi * 1000 * Float(n) / Float(rate))
            input[n] = v
            interleaved[2 * n] = v
            interleaved[2 * n + 1] = side ? -v : v
        }
        let p = DialogueBoostProcessor(sampleRate: rate, stereoSource: stereoSource)
        interleaved.withUnsafeMutableBufferPointer { p.process(interleavedFloat: $0.baseAddress!, frameCount: frames) }
        let left = (0..<frames).map { interleaved[2 * $0] }
        let peak = interleaved.map(abs).max() ?? 0
        return (settledRMS(input), left, peak)
    }

    @Test("quiet speech-level audio comes up and loud audio goes down")
    func rangeIsCompressed() {
        let quiet = process(amplitude: 0.02)    // about -37 dBFS RMS
        let loud = process(amplitude: 0.7)      // about -6 dBFS RMS
        let quietGain = settledRMS(quiet.outLeft) - quiet.inDB
        let loudGain = settledRMS(loud.outLeft) - loud.inDB
        #expect(quietGain > 10, "quiet gained \(quietGain) dB")
        #expect(loudGain < 0, "loud gained \(loudGain) dB")
    }

    @Test("nothing leaves above the limiter's threshold")
    func peaksStayUnderFullScale() {
        let loud = process(amplitude: 1.0)
        #expect(loud.peak <= PeakLimiter.threshold + 0.0001)
    }

    @Test("a two-channel source has its mid raised against its side")
    func stereoSourceFavoursTheMid() {
        // Below the knee, so the compressor applies the same gain to both and the difference is the mid/side stage.
        let mid = process(amplitude: 0.005, stereoSource: true)
        let side = process(amplitude: 0.005, stereoSource: true, side: true)
        let difference = settledRMS(mid.outLeft) - settledRMS(side.outLeft)
        #expect(difference > 2.5 && difference < 3.5, "mid over side by \(difference) dB")
    }

    @Test("the S32 entry point matches the float one")
    func s32MatchesFloat() {
        let rate = 48_000, frames = 4_800
        var f = [Float](repeating: 0, count: frames * 2)
        var s = [Int32](repeating: 0, count: frames * 2)
        for n in 0..<(frames * 2) {
            let v = 0.05 * sinf(Float(n) * 0.05)
            f[n] = v
            s[n] = Int32(Double(v) * 2_147_483_648)
        }
        let pf = DialogueBoostProcessor(sampleRate: rate, stereoSource: false)
        let ps = DialogueBoostProcessor(sampleRate: rate, stereoSource: false)
        f.withUnsafeMutableBufferPointer { pf.process(interleavedFloat: $0.baseAddress!, frameCount: frames) }
        s.withUnsafeMutableBufferPointer { ps.process(interleavedS32: $0.baseAddress!, frameCount: frames) }
        let worst = (0..<(frames * 2)).map { abs(f[$0] - Float(s[$0]) / 2_147_483_648) }.max() ?? 1
        #expect(worst < 1e-5)
    }

    // MARK: - The fold

    /// What a centre-only and a surround-only 5.1 frame of equal level become in the folded left channel.
    private func foldLevels(boost: Bool) throws -> (centre: Float, surround: Float) {
        var inLayout = AVChannelLayout(), outLayout = AVChannelLayout()
        av_channel_layout_default(&inLayout, 6)
        av_channel_layout_default(&outLayout, 2)
        defer { av_channel_layout_uninit(&inLayout); av_channel_layout_uninit(&outLayout) }
        var swr: OpaquePointer?
        guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, 48_000,
                                  &inLayout, AV_SAMPLE_FMT_FLT, 48_000, 0, nil) >= 0, let ctx = swr else {
            throw NSError(domain: "test", code: 1)
        }
        defer { swr_free(&swr) }
        if boost { DialogueBoostProcessor.applyFold(to: ctx) }
        guard swr_init(ctx) >= 0 else { throw NSError(domain: "test", code: 2) }
        // 5.1 order: FL FR FC LFE SL SR.
        func left(of channel: Int) -> Float {
            var input = [Float](repeating: 0, count: 6)
            input[channel] = 0.5
            var output = [Float](repeating: 0, count: 2)
            input.withUnsafeBufferPointer { ip in
                output.withUnsafeMutableBufferPointer { op in
                    var src: UnsafePointer<UInt8>? = UnsafeRawPointer(ip.baseAddress!).assumingMemoryBound(to: UInt8.self)
                    var dst: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(op.baseAddress!)
                        .assumingMemoryBound(to: UInt8.self)
                    _ = swr_convert(ctx, &dst, 1, &src, 1)
                }
            }
            return output[0]
        }
        return (left(of: 2), left(of: 4))
    }

    @Test("the fold puts the centre 9 dB over the surrounds, where the standard one has them level")
    func foldFavoursTheCentre() throws {
        let standard = try foldLevels(boost: false)
        let boosted = try foldLevels(boost: true)
        let standardDB = 20 * log10(standard.centre / standard.surround)
        let boostedDB = 20 * log10(boosted.centre / boosted.surround)
        #expect(abs(standardDB) < 0.1, "standard fold centre over surround: \(standardDB) dB")
        #expect(abs(boostedDB - 9.03) < 0.1, "boosted fold centre over surround: \(boostedDB) dB")
    }

    // MARK: - The bridge

    /// A 16-bit 5.1 WAV with a tone in every channel.
    private func makeWAV(channels: Int, seconds: Double) -> Data {
        let rate = 48_000, frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let v = Int16(6000 * sin(2 * .pi * 440 * Double(n) / Double(rate)))
            for _ in 0..<channels { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    @Test("a 5.1 source with dialogue boost bridges to two-channel 24-bit FLAC and produces audio",
          arguments: [AudioBridgeMode.surroundCompat, .lossless])
    func bridgeFoldsToStereoFLAC(mode: AudioBridgeMode) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: makeWAV(channels: 6, seconds: 0.5)))
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else { throw NSError(domain: "test", code: 1) }
        let bridge = try AudioBridge(srcCodecpar: stream.pointee.codecpar, srcTimeBase: stream.pointee.time_base,
                                     mode: mode, dialogueBoost: true)
        defer { bridge.close() }
        #expect(bridge.outputCodecID == AV_CODEC_ID_FLAC)
        #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 2)
        #expect(bridge.encoderCodecpar?.pointee.bits_per_raw_sample == 24)
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer {
            for o in outputs {
                var oo: UnsafeMutablePointer<AVPacket>? = o
                trackedPacketFree(&oo)
            }
        }
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == audioIdx { outputs.append(contentsOf: try bridge.feed(packet: packet)) }
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        outputs.append(contentsOf: bridge.flush())
        #expect(!outputs.isEmpty)
        #expect(!bridge.feedStats.isSilent)
    }
}
