// W3038: a reopen whose producer writes nothing and waits on a source read that answers nothing.
//
// The reporter's reopen after a 46-minute park read 334 kept packets, wrote none, then sat ~33 s in
// a host source read while AVPlayer asked for init.mp4 every 4 s; its own ~30 s give-up was the only
// exit before the AE#561 rebuild. These hold the guard that offers the session to the software path
// at a map timeout once the producer is seen starved, through the same one-per-session offer.
import AVFoundation
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("Init map starved (W3038)")
struct InitMapStarvedTests {

    @Test("starved only with nothing written, nothing cached and a read parked past the threshold")
    func decision() {
        let threshold = SoftwarePathEscalation.initMapStarvedThresholdSeconds
        #expect(SoftwarePathEscalation.initMapStarved(
            packetsWritten: 0, cachedSegments: 0, readParkedSeconds: threshold))
        #expect(!SoftwarePathEscalation.initMapStarved(
            packetsWritten: 0, cachedSegments: 0, readParkedSeconds: threshold - 0.1),
            "a cold link's connect is not starvation")
        #expect(!SoftwarePathEscalation.initMapStarved(
            packetsWritten: 1, cachedSegments: 0, readParkedSeconds: 30),
            "a producer that wrote has an init segment to serve")
        #expect(!SoftwarePathEscalation.initMapStarved(
            packetsWritten: 0, cachedSegments: 1, readParkedSeconds: 30))
        #expect(!SoftwarePathEscalation.initMapStarved(
            packetsWritten: 0, cachedSegments: 0, readParkedSeconds: 0),
            "a producer not in a read is not waiting on the source")

        #expect(SoftwarePathEscalation.isMapTimeout(
            code: -12889, uri: "http://127.0.0.1:52011/tok/init.mp4", comment: nil))
        #expect(SoftwarePathEscalation.isMapTimeout(
            code: -12889, uri: nil, comment: "No response for map in 4.004s"))
        #expect(!SoftwarePathEscalation.isMapTimeout(
            code: -12889, uri: "http://127.0.0.1:52011/tok/seg698.mp4", comment: "No response for segment"),
            "a media segment's timeout is the stage-2 chain's, not this guard's")
        #expect(!SoftwarePathEscalation.isMapTimeout(
            code: -12888, uri: "http://127.0.0.1:52011/tok/init.mp4", comment: nil))
    }

    @MainActor
    @Test("a map timeout before playback is offered to the software path only while the producer is starved",
          .timeLimit(.minutes(2)), arguments: [true, false])
    func hostOffersOnlyWhileStarved(starved: Bool) async throws {
        // The map timeout, then a loader poison whose stall count says the batch was consumed.
        let snapshot = ItemDiagnosticSnapshot(errors: [
            .init(code: -12889, domain: SoftwarePathEscalation.mediaErrorDomain,
                  comment: "No response for map in 4.004s", uri: "http://127.0.0.1:52011/tok/init.mp4"),
            .init(code: -15628, domain: SoftwarePathEscalation.mediaErrorDomain)])
        let pool = ItemDiagnosticReadPool.withoutReadTimeout()
        let host = NativeAVPlayerHost(diagnosticPool: pool, diagnosticRead: { _, _ in snapshot })
        defer { host.tearDown() }
        host.softwarePathAvailability = {
            .init(alreadyEscalated: false, preferredDecodePath: .automatic, nativeRemoteHLS: false)
        }
        host.initMapStarvedReadSeconds = { starved ? 8 : nil }
        host.load(url: URL(fileURLWithPath: "/nonexistent-init-map-test.m3u8"),
                  startPosition: nil, contract: .init())
        let current = try #require(host.avPlayer.currentItem)
        let stalls = host.stallCount
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: current)
        try await waitFor { host.stallCount == stalls + 1 && pool.runningCount == 0 }

        let request = host.pendingSoftwarePathEscalation
        if starved {
            #expect(request?.code == -12889)
            #expect(request?.domain == SoftwarePathEscalation.mediaErrorDomain)
            #expect(request?.message == "source read parked 8 s, nothing written")
        } else {
            #expect(request?.code != -12889, "a producer that is not starved keeps AVPlayer's own wait")
        }
    }

    @Test("a producer parked in a source read after a mid-file seek reads as starved until the read is released",
          .timeLimit(.minutes(2)))
    func parkedReadAfterSeek() async throws {
        let reader = ParkingReader()
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts")
        #expect(demuxer.seek(to: 4))
        reader.parkAtEnd()
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let video = HLSSegmentProducer.StreamConfig(codecpar: UnsafePointer(stream.pointee.codecpar),
            timeBase: stream.pointee.time_base, codecTagOverride: "avc1")
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        // The resume target lies past every keyframe the source holds, so the gate stays shut and
        // the pump writes nothing, as the reporter's did before its read parked.
        let farTarget: Int64 = 90_000 * 3_600
        let producer = try HLSSegmentProducer(demuxer: demuxer, videoStreamIndex: index,
            video: video, cache: cache, videoFallbackDurationPts: 45_000,
            restartTargetVideoPts: farTarget, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, farTarget])
        let clock = FakeUptime()
        producer.sourceReadClock = { clock.now }
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/reopen.ts"), dvModeAvailable: false)
        engine.demuxer = demuxer
        engine.producer = producer
        engine.cache = cache
        defer { engine.stop(); cache.close() }

        producer.start()
        try await waitFor { reader.isParked }
        #expect(producer.packetsWrittenCount == 0)
        #expect(engine.initMapStarvedReadSeconds == nil, "a read that has just begun is not starved")
        clock.advance(seconds: 7)
        #expect(engine.initMapStarvedReadSeconds == 7)

        // The AE#561 rebuild's teardown releases the read the way a stop() cannot.
        demuxer.markClosed()
        try await waitFor { producer.sourceReadParkedSeconds == 0 }
        #expect(engine.initMapStarvedReadSeconds == nil)
    }

    private final class FakeUptime: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64 = 1_000_000_000_000
        var now: UInt64 { lock.withLock { nanos } }
        func advance(seconds: UInt64) { lock.withLock { nanos += seconds * 1_000_000_000 } }
    }

    /// The fixture, seekable, whose reads past its end park until cancelled once `parkAtEnd()` is
    /// called: a source whose next byte needs a network that does not answer.
    private final class ParkingReader: IOReader, @unchecked Sendable {
        private let bytes = TinyTransportStreamFixture.data
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var position = 0
        private var parks = false
        private var parked = false

        var isParked: Bool { lock.withLock { parked } }
        func parkAtEnd() { lock.withLock { parks = true } }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            let served: Int32? = lock.withLock {
                let n = min(Int(size), bytes.count - position)
                if n <= 0 {
                    guard parks else { return 0 }
                    parked = true
                    return nil
                }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, n) }
                position += n
                return Int32(n)
            }
            if let served { return served }
            release.wait()
            return -1
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            lock.withLock {
                switch whence {
                case 65536: return Int64(bytes.count)   // AVSEEK_SIZE
                case SEEK_SET where offset >= 0 && offset <= Int64(bytes.count): position = Int(offset)
                case SEEK_CUR: position = max(0, min(bytes.count, position + Int(offset)))
                case SEEK_END: position = max(0, min(bytes.count, bytes.count + Int(offset)))
                default: return -1
                }
                return Int64(position)
            }
        }

        func close() {}
        func cancel() { release.signal() }
        var discImageProbeEnabled: Bool { false }
    }
}
