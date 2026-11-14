import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// W2425: 3x plays on the software host, so H.264 there decodes through VideoToolbox from its avcC, as HEVC
/// does from its hvcC, instead of on libavcodec. These pin the choice, the pictures that keep libavcodec
/// (interlaced, MVC both-eyes carriage, live), real hardware decodes of avcC streams, the A53 captions
/// libavcodec used to deliver for them (in presentation order), and a mid-stream parameter-set change.
@Suite("W2425: H.264 decodes on VideoToolbox on the software host")
struct SoftwareHostH264HardwareDecodeTests {

    /// The hardware decodes need VideoToolbox's H.264 decoder, which every Apple silicon host has.
    static let hasHardwareH264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)

    private static func openFixture(_ base64: String, hint: String) throws -> Demuxer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: hint)
        return demuxer
    }

    @MainActor
    @Test("H.264 with a hardware verdict selects HardwareVideoDecoder, without one libavcodec")
    func h264SelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        #expect(host.selectVideoDecoder(
            codecID: AV_CODEC_ID_H264, canHardwareDecode: true, dvProfile: nil) is HardwareVideoDecoder)
        #expect(host.selectVideoDecoder(
            codecID: AV_CODEC_ID_H264, canHardwareDecode: false, dvProfile: nil) is SoftwareVideoDecoder)
    }

    @Test("progressive H.264 may go to VideoToolbox; interlaced and MVC carriage keep libavcodec")
    func pictureRule() throws {
        let progressive = try Self.openFixture(Issue220SoftwareDecoderDrainTests.fixtureBase64, hint: "mp4")
        defer { progressive.close() }
        let stream = try #require(progressive.stream(at: progressive.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(codecpar.pointee.codec_id == AV_CODEC_ID_H264)
        #expect(SoftwarePlaybackHost.h264PictureAllowsVideoToolbox(stream: stream))

        // #107: the deinterlacer runs on libavcodec's frames only.
        let declared = codecpar.pointee.field_order
        codecpar.pointee.field_order = AV_FIELD_TT
        #expect(!SoftwarePlaybackHost.h264PictureAllowsVideoToolbox(stream: stream))
        codecpar.pointee.field_order = declared

        // #435: VideoToolbox renders nothing for both views in one track.
        let mvc = try Self.openFixture(Issue435MultiviewCarriageTests.blockLRBase64, hint: "matroska")
        defer { mvc.close() }
        let mvcStream = try #require(mvc.stream(at: mvc.videoStreamIndex))
        #expect(!SoftwarePlaybackHost.h264PictureAllowsVideoToolbox(stream: mvcStream))
    }

    @Test("the load opens VideoToolbox for VOD progressive H.264; live H.264 and MVC keep libavcodec",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func loadGate() throws {
        let progressive = try Self.openFixture(Issue220SoftwareDecoderDrainTests.fixtureBase64, hint: "mp4")
        defer { progressive.close() }
        let stream = try #require(progressive.stream(at: progressive.videoStreamIndex))
        #expect(SoftwarePlaybackHost.loadOpensVideoToolbox(stream: stream, isLive: false))
        // A live program boundary brings new parameter sets; libavcodec follows them.
        #expect(!SoftwarePlaybackHost.loadOpensVideoToolbox(stream: stream, isLive: true))

        let mvc = try Self.openFixture(Issue435MultiviewCarriageTests.blockLRBase64, hint: "matroska")
        defer { mvc.close() }
        let mvcStream = try #require(mvc.stream(at: mvc.videoStreamIndex))
        #expect(!SoftwarePlaybackHost.loadOpensVideoToolbox(stream: mvcStream, isLive: false))
    }

    @Test("an avcC H.264 stream opens on VideoToolbox, decodes, and keeps its A53 captions",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func avcCDecodesOnHardwareWithCaptions() throws {
        let demuxer = try Self.openFixture(Issue220SoftwareDecoderDrainTests.fixtureBase64, hint: "mp4")
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar).opensHardwareDecoder)
        let framing = A53SEIParser.nalFraming(
            codec: .h264, extradata: codecpar.pointee.extradata, size: Int(codecpar.pointee.extradata_size))
        #expect(framing == .lengthPrefixed(size: 4))

        // One SEI NAL carrying a single CEA-608 pair, put in front of the fifth packet's slice.
        let run = try Self.decodeOnHardware(demuxer) { index in index == 4 ? (0x94, 0x20) : nil }

        #expect(run.packetPTS.count == 40)
        #expect(run.frames.count >= run.packetPTS.count - 16)
        #expect(run.captions.count == 1)
        #expect(run.captions.first?.triplets == [CCDataParser.CCTriplet(type: 0, data0: 0x94, data1: 0x20)])
        #expect(run.captions.first.map { abs($0.pts - run.packetPTS[4]) < 0.001 } == true)
    }

    /// Review HOLD 1: VideoToolbox hands frames over out of presentation order (PERF-104), so the captions
    /// leave with each packet sent, in decode order with its DTS, and the tap's reorder buffer sorts them as it
    /// does the HLS producer's. Fed the way `AetherEngine+Loading` routes them, a roll-up or pop-on line made of
    /// one pair per picture of a B-frame stream comes out in presentation order.
    @Test("captions of a B-frame stream reach the tap in presentation order",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func bFrameCaptionsInPresentationOrder() throws {
        let demuxer = try Self.openFixture(H264HardwareDecodeFixtures.bFramesBase64, hint: "mp4")
        defer { demuxer.close() }
        // Packet i (decode order) carries pair (0x40 + i, 0x01).
        let run = try Self.decodeOnHardware(demuxer) { index in (UInt8(0x40 + index), 0x01) }
        let packets = run.packetPTS.count
        #expect(packets == 24)
        #expect(run.packetPTS != run.packetPTS.sorted(), "the fixture's pictures are reordered")
        #expect(run.captions.count == packets)
        #expect(run.captions.allSatisfy { if case .decode(dts: _?) = $0.order { true } else { false } },
                "VideoToolbox's come in decode order with their DTS")
        Self.expectPresentationOrderAtTheTap(run)
    }

    /// W2425 a2 fix 4: Matroska stores no DTS, so the first packets of a B-frame MKV reach the tap with none. Taking
    /// their PTS for one moved the reorder buffer's watermark past the B-frames still to come, and every group of the
    /// stretch after left misordered; held without a watermark, the whole stretch comes out in presentation order.
    @Test("captions of a whole B-frame Matroska stretch reach the tap in presentation order",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func bFrameMatroskaCaptionsInPresentationOrder() throws {
        let demuxer = try Self.openFixture(H264HardwareDecodeFixtures.bFramesMatroskaBase64, hint: "matroska")
        defer { demuxer.close() }
        let run = try Self.decodeOnHardware(demuxer) { index in (UInt8(0x40 + index), 0x01) }
        #expect(run.packetPTS.count == 24)
        #expect(run.packetPTS != run.packetPTS.sorted(), "the fixture's pictures are reordered")
        #expect(run.captions.count == 24)
        #expect(run.captions.contains { $0.order == .decode(dts: nil) }, "Matroska's first packets carry no DTS")
        Self.expectPresentationOrderAtTheTap(run)
    }

    /// Feeds the run's captions the way `AetherEngine+Loading` routes them; packet i carries pair (0x40 + i, 0x01).
    private static func expectPresentationOrderAtTheTap(
        _ run: Run, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var reorder = A53ReorderBuffer()
        var fed: [A53ReorderBuffer.Group] = []
        for caption in run.captions {
            let pairs = caption.triplets.map { A53ReorderBuffer.Pair(d0: $0.data0, d1: $0.data1) }
            switch caption.order {
            case .decode(let dts): fed += reorder.insert(pts: caption.pts, pairs: pairs, dts: dts)
            case .presentation: fed.append(.init(pts: caption.pts, pairs: pairs))
            }
        }
        let presentationOrder = run.packetPTS.indices.sorted { run.packetPTS[$0] < run.packetPTS[$1] }
            .map { UInt8(0x40 + $0) }
        #expect(fed.count >= run.packetPTS.count - 3, "all but the reorder depth are out",
                sourceLocation: sourceLocation)
        #expect(fed.flatMap { $0.pairs.map(\.d0) } == Array(presentationOrder.prefix(fed.count)),
                sourceLocation: sourceLocation)
    }

    /// Review HOLD 2: VideoToolbox keeps the format description it opened with, so a keyframe with new
    /// parameter sets (a recording's 1080/720 or 4:3/16:9 switch) moves the session onto them. A session rebuilt
    /// for them first hands over the pictures VideoToolbox still held back for reordering (W2425 a2a).
    @Test("a mid-stream SPS/PPS change keeps decoding, at the new size, every frame before it too",
          .enabled(if: hasHardwareH264, "needs VideoToolbox's H.264 hardware decoder"))
    func parameterSetChangeKeepsDecoding() throws {
        let demuxer = try Self.openFixture(H264HardwareDecodeFixtures.parameterSetChangeBase64, hint: "matroska")
        defer { demuxer.close() }
        let run = try Self.decodeOnHardware(demuxer) { _ in nil }
        #expect(run.packetPTS.count == 24)
        let widths = run.frames.map(\.width)
        #expect(widths.filter { $0 == 64 }.count == 12)
        #expect(widths.filter { $0 == 96 }.count == 12)
    }

    // MARK: - Decode harness

    private struct Caption {
        let triplets: [CCDataParser.CCTriplet]
        let pts: Double
        let order: A53CaptionOrder
    }

    private struct Run {
        var packetPTS: [Double] = []
        var frames: [(width: Int, pts: Double)] = []
        var captions: [Caption] = []
    }

    /// Decodes every video packet on a HardwareVideoDecoder, putting an SEI NAL with `caption(i)`'s pair in
    /// front of packet i (decode order) when it gives one.
    private static func decodeOnHardware(
        _ demuxer: Demuxer, caption: (Int) -> (UInt8, UInt8)?
    ) throws -> Run {
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let tb = stream.pointee.time_base
        let frames = Recorder<(width: Int, pts: Double)>()
        let captions = Recorder<Caption>()
        let decoder = HardwareVideoDecoder()
        decoder.onA53Captions = { triplets, pts, order in
            captions.append(Caption(triplets: triplets, pts: pts, order: order))
        }
        try decoder.open(stream: stream) { pixelBuffer, pts, _ in
            frames.append((CVPixelBufferGetWidth(pixelBuffer), pts.seconds))
        }
        var run = Run()
        while let pkt = try? demuxer.readPacket() {
            var read: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&read) }
            guard pkt.pointee.stream_index == videoIndex else { continue }
            let index = run.packetPTS.count
            run.packetPTS.append(Double(pkt.pointee.pts) * Double(tb.num) / Double(tb.den))
            guard let pair = caption(index), let data = pkt.pointee.data else {
                decoder.decode(packet: pkt)
                continue
            }
            let sei: [UInt8] = [0x06, 0x04, 0x0E, 0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03, 0x41, 0xFF,
                                0xFC, pair.0, pair.1, 0xFF, 0x80]
            let seiNAL: [UInt8] = [0, 0, 0, UInt8(sei.count)] + sei
            let joined = try #require(av_packet_alloc())
            var owned: UnsafeMutablePointer<AVPacket>? = joined
            defer { av_packet_free(&owned) }
            #expect(av_new_packet(joined, Int32(seiNAL.count) + pkt.pointee.size) == 0)
            #expect(av_packet_copy_props(joined, pkt) == 0)
            let out = try #require(joined.pointee.data)
            seiNAL.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: seiNAL.count) }
            (out + seiNAL.count).update(from: data, count: Int(pkt.pointee.size))
            decoder.decode(packet: joined)
        }
        decoder.flush()
        decoder.close()   // waits for VideoToolbox's asynchronous frames
        run.frames = frames.values
        run.captions = captions.values
        return run
    }

    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
