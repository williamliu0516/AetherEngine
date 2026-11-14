import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// W2425 a2a: an H.264 stream VideoToolbox opened can switch, at a keyframe, to parameter sets it refuses (High 10,
/// 4:2:2) or to interlaced pictures it weaves; the software host then moves video to libavcodec at the playhead,
/// once, through the decoder slot its running demux loop feeds.
@Suite("W2425: VideoToolbox hands a switched H.264 stream to libavcodec")
struct SoftwareHostH264FallbackTests {

    static let hasHardwareH264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)

    private static func openFixture(_ base64: String) throws -> Demuxer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        return demuxer
    }

    // MARK: - The slot

    @Test("a packet read for the decoder before a swap or a flush is refused by the slot")
    func slotRefusesPacketsFromBeforeASwap() throws {
        let hardware = CountingDecoder()
        let software = CountingDecoder()
        let slot = VideoDecoderSlot(hardware)
        let packet = try #require(av_packet_alloc())
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }

        slot.decode(packet: packet, epoch: slot.feedEpoch)
        #expect(hardware.decoded == 1)

        let readBeforeSwap = slot.feedEpoch
        slot.replace(with: software)
        slot.decode(packet: packet, epoch: readBeforeSwap)
        #expect(software.decoded == 0, "the new decoder counts its own epochs from 0 too")
        #expect(hardware.decoded == 1)
        slot.decode(packet: packet, epoch: slot.feedEpoch)
        #expect(software.decoded == 1)

        let readBeforeFlush = slot.feedEpoch
        slot.flush()
        #expect(software.flushes == 1)
        slot.decode(packet: packet, epoch: readBeforeFlush)
        #expect(software.decoded == 1)
        slot.decode(packet: packet, epoch: nil)   // the DVR ring's replay carries none
        #expect(software.decoded == 2)
    }

    // MARK: - HardwareVideoDecoder

    @Test("a High 10 or 4:2:2 switch VideoToolbox takes decodes on, with no ask for libavcodec",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"),
          arguments: ["High 10", "4:2:2"])
    func acceptedSwitchKeepsDecoding(_ to: String) throws {
        let fixture = to == "High 10"
            ? H264HardwareDecodeFixtures.highTenSwitchBase64 : H264HardwareDecodeFixtures.fourTwoTwoSwitchBase64
        let run = try Self.decodeOnHardware(Self.openFixture(fixture))
        #expect(run.packets == 24)
        #expect(run.reasons.isEmpty)
        #expect(run.frames.filter { $0 < 0.49 }.count == 12)
        #expect(run.frames.filter { $0 > 0.49 }.count == 12)
    }

    @Test("VideoToolbox refusing a switch asks for libavcodec once, keeps the frames before it, drops the rest",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func refusedSwitchAsksForLibavcodec() throws {
        let run = try Self.decodeOnHardware(
            Self.openFixture(H264HardwareDecodeFixtures.highTenSwitchBase64), refusingSwitch: true)
        #expect(run.packets == 24)
        #expect(run.reasons == [.refused])
        #expect(run.sessionsLost == 0, "a refused switch is not a lost session: its rebuild retries the refused sets")
        #expect(run.frames.filter { $0 < 0.49 }.count == 12, "every frame before the switch")
        #expect(run.frames.filter { $0 > 0.49 }.isEmpty, "nothing fed to a session that cannot decode it")
    }

    /// Whether VideoToolbox then decodes the interlaced pictures (woven) is the platform's: the Mac's refuses them.
    @Test("an interlaced switch asks for libavcodec once, as interlaced, keeping the frames before it",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func interlacedSwitchAsksForLibavcodec() throws {
        let run = try Self.decodeOnHardware(Self.openFixture(H264HardwareDecodeFixtures.interlacedSwitchBase64))
        #expect(run.packets == 24)
        #expect(run.reasons == [.interlaced])
        #expect(run.sessionsLost == 0)
        #expect(run.frames.filter { $0 < 0.49 }.count == 12)
    }

    // MARK: - The host

    @MainActor
    @Test("a refused switch moves video to libavcodec once, and frames resume at the playhead",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func hostFallsBackOnARefusedSwitch() async throws {
        try await Self.playUntilFallback(H264HardwareDecodeFixtures.highTenSwitchBase64, reason: .refused,
                                         refusingSwitch: true)
    }

    @MainActor
    @Test("an interlaced switch moves video to libavcodec once, and frames resume at the playhead",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func hostFallsBackOnAnInterlacedSwitch() async throws {
        try await Self.playUntilFallback(H264HardwareDecodeFixtures.interlacedSwitchBase64, reason: .interlaced)
    }

    @MainActor
    private static func playUntilFallback(
        _ fixture: String, reason: HardwareFallbackReason, refusingSwitch: Bool = false
    ) async throws {
        let host = SoftwarePlaybackHost()
        defer { host.stop() }
        let frames = Recorder<(pts: Double, hardware: Bool)>()
        host.onVideoFrameEnqueuedForTesting = { pts, hardware in frames.append((pts.seconds, hardware)) }
        try await host.load(demuxer: openFixture(fixture), startPosition: nil, audioSourceStreamIndex: nil)
        #expect(host.usesHardwareVideoDecoder)
        if refusingSwitch {
            let hardware = try #require(host.videoDecoderForTesting as? HardwareVideoDecoder)
            hardware.refusesFormatForTesting = { _ in true }
        }
        host.play()
        await waitUntil { frames.values.contains { !$0.hardware && $0.pts > 0.49 } }

        let fallback = try #require(host.hardwareFallback, "VideoToolbox never handed the stream over")
        #expect(fallback.reason == reason)
        #expect(!host.usesHardwareVideoDecoder)
        let software = frames.values.filter { !$0.hardware }.map(\.pts)
        let first = try #require(software.first)
        #expect(first >= fallback.playhead - 0.001 && first < fallback.playhead + 0.1,
                "libavcodec's first frame is the playhead's (\(first) for \(fallback.playhead))")
        #expect(software.contains { $0 > 0.49 }, "past the switch")

        // No second fallback: another ask, the way a second keyframe's would come, changes nothing.
        let decoder = host.videoDecoderForTesting
        await host.fallBackToLibavcodec(reason: reason == .refused ? .interlaced : .refused)
        #expect(host.videoDecoderForTesting === decoder)
        #expect(host.hardwareFallback == fallback)
    }

    // MARK: - Harness

    private struct Run {
        var packets = 0
        var frames: [Double] = []
        var widths: [Int] = []
        var reasons: [HardwareFallbackReason] = []
        var sessionsLost = 0
    }

    /// `refusingSwitch`: VideoToolbox refuses every description after the one it opened on.
    private static func decodeOnHardware(_ demuxer: Demuxer, refusingSwitch: Bool = false) throws -> Run {
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let frames = Recorder<(pts: Double, width: Int)>()
        let reasons = Recorder<HardwareFallbackReason>()
        let lost = Recorder<Void>()
        let decoder = HardwareVideoDecoder()
        decoder.onHardwareFallbackNeeded = { reasons.append($0) }
        decoder.onSessionLost = { lost.append(()) }
        try decoder.open(stream: stream) { pixelBuffer, pts, _ in
            frames.append((pts.seconds, CVPixelBufferGetWidth(pixelBuffer)))
        }
        if refusingSwitch { decoder.refusesFormatForTesting = { _ in true } }
        var run = Run()
        while let pkt = try? demuxer.readPacket() {
            var read: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&read) }
            guard pkt.pointee.stream_index == videoIndex else { continue }
            run.packets += 1
            decoder.decode(packet: pkt)
        }
        decoder.flush()
        decoder.close()   // waits for VideoToolbox's asynchronous frames
        run.frames = frames.values.map(\.pts)
        run.widths = frames.values.map(\.width)
        run.reasons = reasons.values
        run.sessionsLost = lost.values.count
        return run
    }

    // test-wait: real VideoToolbox and libavcodec decodes on the host's own demux thread and clock; no fake
    // clock reaches them.
    @MainActor
    private static func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private final class CountingDecoder: VideoDecodingPipeline, @unchecked Sendable {
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: A53CaptionHandler?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        private let lock = NSLock()
        private var epoch: UInt64 = 0
        private var _decoded = 0
        private var _flushes = 0
        var decoded: Int { lock.withLock { _decoded } }
        var flushes: Int { lock.withLock { _flushes } }
        var feedEpoch: UInt64 { lock.withLock { epoch } }
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
            lock.withLock {
                if let epoch, epoch != self.epoch { return }
                _decoded += 1
            }
        }
        func flush() { lock.withLock { epoch &+= 1; _flushes += 1 } }
        func close() {}
    }

    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) { lock.withLock { storage.append(value) } }
        var values: [Value] { lock.withLock { storage } }
    }
}
