import Foundation
import Testing
@testable import AetherEngine

/// W3146: a restart stopping a pump parked in a network read ends that read and goes on with the same demuxer. Before,
/// `stop()` could not end the read and the restart waited out its whole 5 s (a cloud drive's reader, a 4K Dolby
/// Vision film: every seek whose old pump was waiting for bytes paid it, then the #79 fallback).
@Suite("A restart interrupts its old pump's read", .serialized)
struct RestartStopInterruptsReadTests {

    /// Serves the fixture a few bytes at a time and, once armed, parks the read that reaches `blockAt` until the
    /// engine cancels it, as a network reader whose `cancel()` only unblocks: the parked read gives up with -1, and
    /// reads after it work (the source answers again).
    private final class NetworkLikeReader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let condition = NSCondition()
        private var position = 0
        private var blockAt: Int?
        private var parked = false
        private var cancels = 0
        private var released = false

        init(_ bytes: Data) { self.bytes = bytes }

        func arm(blockAt offset: Int) { condition.withLock { blockAt = offset } }
        var isParked: Bool { condition.withLock { parked } }
        /// Ends a parked read for good (test cleanup).
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            condition.lock()
            defer { condition.unlock() }
            if let blockAt, position >= blockAt {
                parked = true
                let before = cancels
                while cancels == before && !released { condition.wait() }
                parked = false
                self.blockAt = nil
                return -1
            }
            var n = min(Int(size), 64, bytes.count - position)
            if let blockAt { n = min(n, blockAt - position) }
            guard n > 0 else { return 0 }
            bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
            position += n
            return Int32(n)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            condition.withLock {
                switch whence {
                case 65536: return Int64(bytes.count)
                case SEEK_SET: position = Int(max(0, min(offset, Int64(bytes.count))))
                case SEEK_CUR: position = max(0, min(position + Int(offset), bytes.count))
                case SEEK_END: position = max(0, min(bytes.count + Int(offset), bytes.count))
                default: return -1
                }
                return Int64(position)
            }
        }

        func cancel() {
            condition.lock()
            cancels += 1
            condition.broadcast()
            condition.unlock()
        }

        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    /// Past everything the open's stream probe reads in the Issue234 fixture (15 s of H.264 at 5 fps in Matroska).
    private static let parkOffset = 2237

    @Test("a restart's stop ends a parked read in well under a second and the demuxer reads on",
          .timeLimit(.minutes(1)))
    func stopEndsTheParkedRead() async throws {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let reader = NetworkLikeReader(data)
        defer { reader.release() }
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }
        reader.arm(blockAt: Self.parkOffset)

        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        defer { cache.close() }
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: nil),
            cache: cache, videoFallbackDurationPts: 200, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 15_000])
        producer.start()
        try await waitFor { reader.isParked }

        let start = DispatchTime.now()
        let exited = HLSVideoEngine.stopForRestart(producer, demuxers: [demuxer], interrupting: true, timeout: 5.0)
        let waited = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(exited, "the old pump was still in its read after \(waited) s")
        #expect(waited < 1.0, "the stop waited \(waited) s")

        // The next producer reuses this demuxer: it seeks back and reads.
        #expect(demuxer.seek(to: 0, streamIndex: videoIndex))
        let packet = try demuxer.readPacket()
        #expect(packet != nil, "the demuxer read nothing after the interrupt")
        var freed = packet
        trackedPacketFree(&freed)
    }
}
