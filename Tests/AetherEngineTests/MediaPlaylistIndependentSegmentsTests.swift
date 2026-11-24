import Testing
import Foundation
@testable import AetherEngine

/// W3160: every media playlist the engine serves declares EXT-X-INDEPENDENT-SEGMENTS, not only the master. Without it
/// on the bare media playlist (useMaster=false) AVPlayer backed a first seek made in play's first ~8 s up to the
/// segment holding target - 8 s (seek at 3 s on a 51 Mbps DV file: two segments early, 10.7 s to land). Each segment
/// the engine cuts starts on a keyframe, live ones too, so live declares it as well.
@Suite
struct MediaPlaylistIndependentSegmentsTests {

    private static let tag = "#EXT-X-INDEPENDENT-SEGMENTS"

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Declared once, in the header, before the first segment.
    private func declaresIndependent(_ text: String) -> Bool {
        let l = lines(text)
        guard l.filter({ $0 == Self.tag }).count == 1, let at = l.firstIndex(of: Self.tag) else { return false }
        let firstSegment = l.firstIndex { $0.hasPrefix("#EXTINF") } ?? l.count
        return at < firstSegment
    }

    private func vodProvider(cache: SegmentCache, codecs: String, range: HLSVideoRange) -> VideoSegmentProvider {
        let segments = (0..<5).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i) * 4000 + 4000,
                                   startSeconds: Double(i) * 4, durationSeconds: 4)
        }
        return VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: codecs, supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: range, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 50_000_000)
    }

    @Test("a VOD file's media playlist and master declare it, Dolby Vision and SDR",
          arguments: [("dvh1.08.06", HLSVideoRange.pq), ("hvc1.2.4.L150.B0", .pq), ("avc1.640028", .sdr)])
    func vod(codecs: String, range: HLSVideoRange) {
        let cache = SegmentCache()
        defer { cache.close() }
        let provider = vodProvider(cache: cache, codecs: codecs, range: range)
        let media = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        #expect(declaresIndependent(media), "media playlist for \(codecs):\n\(media)")
        #expect(lines(media).contains("#EXT-X-ENDLIST"))
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(declaresIndependent(master), "master for \(codecs):\n\(master)")
    }

    private final class TypedProvider: HLSSegmentProvider, @unchecked Sendable {
        let type: HLSPlaylistType
        init(type: HLSPlaylistType) { self.type = type }
        func initSegment() -> Data? { Data([0x00]) }
        func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
        var segmentCount: Int { 4 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { type }
        var liveTargetSegmentDuration: Double? { 4.0 }
    }

    @Test("an event and a live media playlist declare it too", arguments: [HLSPlaylistType.event, .live])
    func eventAndLive(type: HLSPlaylistType) {
        let media = HLSLocalServer.buildMediaPlaylistText(provider: TypedProvider(type: type))
        #expect(declaresIndependent(media), "\(type):\n\(media)")
    }
}
