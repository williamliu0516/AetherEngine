import CoreMedia
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// W2425: 3x plays on the software host, so H.264 there decodes through VideoToolbox from its avcC, as HEVC
/// does from its hvcC, instead of on libavcodec. These pin the choice, the pictures that keep libavcodec
/// (interlaced, MVC both-eyes carriage), a real hardware decode of an avcC stream, and the A53 captions
/// libavcodec used to deliver for it.
@Suite("W2425: H.264 decodes on VideoToolbox on the software host")
struct SoftwareHostH264HardwareDecodeTests {

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

    @Test("an avcC H.264 stream opens on VideoToolbox, decodes, and keeps its A53 captions")
    func avcCDecodesOnHardwareWithCaptions() throws {
        let demuxer = try Self.openFixture(Issue220SoftwareDecoderDrainTests.fixtureBase64, hint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar).opensHardwareDecoder)
        let framing = A53SEIParser.nalFraming(
            codec: .h264, extradata: codecpar.pointee.extradata, size: Int(codecpar.pointee.extradata_size))
        #expect(framing == .lengthPrefixed(size: 4))

        let frames = Recorder<Double>()
        let captions = Recorder<(CCDataParser.CCTriplet, Double)>()
        let decoder = HardwareVideoDecoder()
        decoder.onA53Captions = { triplets, pts in
            for triplet in triplets { captions.append((triplet, pts)) }
        }
        try decoder.open(stream: stream) { _, pts, _ in frames.append(pts.seconds) }

        // One SEI NAL carrying a single CEA-608 pair, put in front of the fifth packet's slice.
        let sei: [UInt8] = [0x06] + A53SEIParserTests.seiRBSPOneTriplet
        let seiNAL: [UInt8] = [0, 0, 0, UInt8(sei.count)] + sei
        let tb = stream.pointee.time_base
        var packets = 0
        var captionedPTS: Double?
        while let pkt = try? demuxer.readPacket() {
            var read: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&read) }
            guard pkt.pointee.stream_index == videoIndex else { continue }
            packets += 1
            guard packets == 5, let data = pkt.pointee.data else {
                decoder.decode(packet: pkt)
                continue
            }
            let joined = try #require(av_packet_alloc())
            var owned: UnsafeMutablePointer<AVPacket>? = joined
            defer { av_packet_free(&owned) }
            #expect(av_new_packet(joined, Int32(seiNAL.count) + pkt.pointee.size) == 0)
            #expect(av_packet_copy_props(joined, pkt) == 0)
            let out = try #require(joined.pointee.data)
            seiNAL.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: seiNAL.count) }
            (out + seiNAL.count).update(from: data, count: Int(pkt.pointee.size))
            captionedPTS = Double(pkt.pointee.pts) * Double(tb.num) / Double(tb.den)
            decoder.decode(packet: joined)
        }
        decoder.flush()
        decoder.close()   // waits for VideoToolbox's asynchronous frames

        #expect(packets == 40)
        #expect(frames.values.count >= packets - 16)
        let expectedPTS = try #require(captionedPTS)
        #expect(captions.values.count == 1)
        #expect(captions.values.first?.0 == CCDataParser.CCTriplet(type: 0, data0: 0x94, data1: 0x20))
        #expect(captions.values.first.map { abs($0.1 - expectedPTS) < 0.001 } == true)
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
