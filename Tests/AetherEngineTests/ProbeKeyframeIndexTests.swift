import Testing
import Foundation
@testable import AetherEngine

/// `ProbeDetail.keyframeIndex`: a warm loads the index bytes a session's start would fetch (a Matroska file's Cues,
/// written after the media), so a reader that keeps what it read hands them to the later `load()`.
@Suite("Probe keyframe index")
struct ProbeKeyframeIndexTests {

    /// A minute of 8 kHz mono silence as PCM in Matroska (ffmpeg's muxer, which writes the Cues after the media,
    /// 964 240 bytes), raw-deflated: the engine's FFmpeg build has no Matroska muxer to make it here.
    ///     ffmpeg -f lavfi -i aevalsrc=0:s=8000:d=60 -c:a pcm_s16le -ac 1 fixture.mkv
    private static func matroska() throws -> Data {
        let encoded = deflated.joined()
        guard let packed = Data(base64Encoded: encoded) else { throw NSError(domain: "test", code: 1) }
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    private static let deflated: [String] = [
        "7dldiOVlAcfx/zlz5uXM25kzp6IcYRoljL1YZ4uEWYhd56XactdwVowIZBxzRVPD8QhJF3POHnenVEqKQNwQW2+WfEF0R2KQY1iy",
        "vSBGoFEX0k1TkPlSZHXVzDRDed/d7/OBvTjPPjt7dq++/J6LFl4/e3b2VKs0++7Wr3daldm/tgZm22u3Ld115x0rty7Nnt46urdV",
        "/uDi6olSsWV0/Uv1ow/f9eNuZ2npT+eObty3+MPO+4+cu2nx8daj//n0geNP3rr16c2jG/dvfRo//uKJxcfbpU8f3Xhg6+PFixtb",
        "v3ly9Pztf975cUVxTfF/t/19ftbt1K+7+OZ9rz19sjZ7+Ojq/Vct3X3TFR/ff2D/gemPXXflez6uPPbt+e7+S+780EMv/f2lc1/8",
        "/t8WavPfWDv8xlU7P2373/Prbmf51dlnn9z9zvOvtUorP107NPnKvuefuGXfmVZxyfkzJ5u337jWKk49cOX1n587evmRY8cvv+rI",
        "8ZOt8u8ffKRVOr92uHt45w/fcGNr7Nq/tIrt/5nDJ7udxffte2Nl5ZHlF1ZPXHho4ezphWNzV88vXDN/+r3fceU3yy/ct/zfv/TE",
        "hbP/e/l7W5eX9y5/+KvLt12/cuCKr3z5xIVHF86uzV97zZXHj1x9bP70d6anD04fODg9vX96TzE5t96cmrmo23nsV+v3bLaKs5+p",
        "tIpitQAA4uxkwKoMAIDQDChZAwAgNgOsAQCQmgFlawAAxGaANQAAUjOgxxoAALEZYA0AgNQMqFgDACA2A6wBAJCaAb3WAACIzQBr",
        "AACkZkCfNQAAYjPAGgAAqRnQbw0AgNgMsAYAQGoGDFgDACA2A6wBAJCaAVVrAADEZoA1AABSM2DQGgAAsRlgDQCA1AwYsgYAQGwG",
        "WAMAIDUDhq0BABCbAdYAAEjNgBFrAADEZoA1AABSM2DUGgAAsRlgDQCA1AyoWQMAIDYDrAEAkJoBY9YAAIjNAGsAAKRmQN0aAACx",
        "GWANAIDUDBi3BgBAbAZYAwAgNQMa1gAASDQ5t96cmpnodm549tTnNtuN1e0uKHQBAKTOA4VXAgBIzYCSNQAAYjPAGgAAqRlQtgYA",
        "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",
    ]

    private func furthestRead(detecting: ProbeDetail, data: Data) throws -> Int64 {
        let reader = ProbeRecordingReader(data: data)
        _ = try AetherEngine.probe(source: .custom(reader), detecting: detecting,
                                   limits: ProbeLimits(maxInputBytes: 16 * 1024 * 1024, timeBudget: 10))
        return reader.reads.map { $0.offset + Int64(max(0, $0.returned)) }.max() ?? 0
    }

    @Test("with the index pass the probe reads the Cues behind the media; without it, the head only")
    func indexPassReadsTheIndex() throws {
        let data = try Self.matroska()
        let size = Int64(data.count)
        #expect(size > 900_000, "fixture: a minute of blocks")
        let plain = try furthestRead(detecting: [], data: data)
        let indexed = try furthestRead(detecting: .keyframeIndex, data: data)
        #expect(plain < size * 4 / 10, "a header probe stays in the head (read to \(plain) of \(size))")
        #expect(indexed > size * 9 / 10, "the index pass reaches the Cues behind the media (read to \(indexed) of \(size))")
    }
}
