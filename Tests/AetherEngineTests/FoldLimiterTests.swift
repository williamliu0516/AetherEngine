import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Zool's fork: folding 7.1 into the E-AC-3 bridge's 5.1 adds each back channel to its side channel at full weight,
/// and libswresample does not normalize a float rematrix: 环太平洋's climax peaked at 1.43 in the side channels, and
/// E-AC-3 carried the overs to the decoder (Zool on a MacBook, Diagnostics 81: crackle). The bridge then runs the
/// shaping graph with nothing to shape, which is its limiter alone.
@Suite("Fold limiter")
struct FoldLimiterTests {
    @Test("the limiter runs where the E-AC-3 bridge folds channels with no shaping, and nowhere else")
    func onlyAFoldIntoEAC3() {
        let none = AudioShaping()
        let folds = AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 8, encoderChannels: 6,
                                                 shaping: none)
        let same = AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 6, encoderChannels: 6,
                                                shaping: none)
        let flac = AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_FLAC, sourceChannels: 8, encoderChannels: 8,
                                                shaping: none)
        let shaped = AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_EAC3, sourceChannels: 8, encoderChannels: 2,
                                                  shaping: AudioBoost.shaping(dialogue: true, volume: 1))
        #expect(folds)
        #expect(!same)
        #expect(!flac)
        #expect(!shaped)
        let chain = AudioShapingGraph.chain(shaping: none, stereoDialogueEnhance: false, outputFormat: AV_SAMPLE_FMT_FLT,
                                            layoutDescription: "5.1")
        #expect(chain.hasPrefix("alimiter="))
    }

    @Test("with nothing to shape the graph holds a fold's 1.43 under full scale and leaves ordinary levels alone")
    func theLimiterAloneHoldsTheFoldsPeaks() throws {
        let frames = 9_600, channels = 6
        var loud = [Float](repeating: 0, count: frames * channels)
        var quiet = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let wave = Float(sin(Double(f) * 2 * .pi * 440 / 48_000))
            loud[f * channels + 4] = 1.43 * wave   // a side channel, the back one folded in
            loud[f * channels + 2] = 0.5 * wave
            quiet[f * channels + 2] = 0.5 * wave
        }
        let held = try run(loud, channels: Int32(channels))
        let heldPeak = held.map { abs($0) }.max() ?? 0
        #expect(held.count == loud.count)
        #expect(heldPeak <= 0.9)
        let untouched = try run(quiet, channels: Int32(channels))
        let drift = zip(untouched, quiet).map { abs($0 - $1) }.max() ?? 1
        #expect(untouched.count == quiet.count)
        #expect(drift < 0.001)
    }

    /// Interleaved Float32 through a graph with nothing to shape, drained.
    private func run(_ input: [Float], channels: Int32) throws -> [Float] {
        var layout = AVChannelLayout()
        defer { av_channel_layout_uninit(&layout) }
        av_channel_layout_default(&layout, channels)
        let built = AudioShapingGraph(shaping: AudioShaping(), sampleRate: 48_000, layout: &layout,
                                      sourceHasCentre: true, outputFormat: AV_SAMPLE_FMT_FLT)
        let graph = try #require(built)
        var out: [Float] = []
        let ch = Int(channels)
        let collect: ([UnsafeMutableRawPointer?], Int, Int64?) -> Void = { planes, count, _ in
            let base = planes[0]!.assumingMemoryBound(to: Float.self)
            out.append(contentsOf: UnsafeBufferPointer(start: base, count: count * ch))
        }
        let frames = input.count / ch
        input.withUnsafeBufferPointer { buf in
            var at = 0
            while at < frames {
                let n = min(1000, frames - at)
                graph.process(buf.baseAddress! + at * ch, frames: n, pts: Int64(at), emit: collect)
                at += n
            }
        }
        graph.drain(emit: collect)
        return out
    }
}
