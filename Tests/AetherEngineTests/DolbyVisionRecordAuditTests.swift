import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// AE#532: a Dolby Vision container record its own RPU contradicts.
///
/// A Profile 5 record over a bitstream whose VUI declares BT.2020 YCbCr with an HDR transfer is a
/// contradiction the file states itself, because IPT-PQ-c2 has no VUI code point and a genuine
/// Profile 5 leaves both fields unspecified. The RPU settles it: a Profile 5 RPU cannot carry a
/// residual or an NLQ, so an RPU that does is proof the record is wrong rather than a guess about it.
///
/// The two RPU NALs below are real, lifted from the first frame of Dolby's own Profile 5 asset and of
/// a Profile 8.1 remux, so the parse under test is the parse a source performs.
@Suite("AE#532: the RPU settles a contradicted Dolby Vision record")
struct DolbyVisionRecordAuditTests {

    // MARK: - Harness

    /// First `unspec62` NAL of Dolby's "Patterns of Nature" Profile 5 asset (189 B).
    /// `dovi_tool info`: `dovi_profile: 5`, `vdr_rpu_profile=0`, `disable_residual_flag=true`.
    private static let genuineProfile5RPU =
        "7c01190809004061b6506f003ff801ffc00fffd000000800000680000040000034000003" +
        "0200000301a2000031f06912000fc5b04432000010bea570000003000080000003008000" +
        "00042b9fea3fea3fea342b9fea3fea3fea342b9ffff000000300000300000300064207dc" +
        "e015083008007ffc0000c028215117ee42b80080040001805646f36ffede900100080003" +
        "00b01df6e009e2a002001000080800400220140000030000030000030048307d00019000" +
        "000300004262c55680"

    /// First `unspec62` NAL of a real Profile 8.1 remux (139 B).
    /// `dovi_tool info`: `dovi_profile: 8`, `vdr_rpu_profile=1`.
    private static let realProfile81RPU =
        "7c0119080908406136506f003ff801ffc00fffd000000800000680000040000034000003" +
        "0200000301a2566000035ea2566f9fceb1c256644ca00000100000030080000003008000" +
        "000301c36224301860a5e308e0514000001a63e5affff000000300000300000300060200" +
        "f80e1530100a0000030000030000030024180fa000040fa00640a3c503f380"

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2)
            return UInt8(hex[s..<e], radix: 16)!
        }
    }

    /// 2-byte HEVC NAL header (type in bits 1..6 of byte 0) + payload, the shape of a synthetic NAL.
    private static func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// Pack NALs into an AVCC (4-byte BE length prefix) packet, the framing the MP4/MKV demuxer gives.
    private static func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var out: [UInt8] = []
        for nal in nals {
            let n = nal.count
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            out.append(contentsOf: nal)
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(out.count))
        out.withUnsafeBytes { src in _ = memcpy(pkt.pointee.data, src.baseAddress, out.count) }
        return pkt
    }

    private static func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }

    // MARK: - What the RPU says

    @Test("a real Profile 5 RPU reports profile 5")
    func genuineProfile5RPUReportsFive() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.genuineProfile5RPU)])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == 5)
    }

    @Test("a real Profile 8.1 RPU reports profile 8")
    func realProfile81RPUReportsEight() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.realProfile81RPU)])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == 8)
    }

    @Test("a packet with no RPU NAL says nothing")
    func packetWithoutRPUSaysNothing() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA, 0xBB])])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == nil)
    }

    @Test("an unparseable RPU says nothing rather than guessing")
    func malformedRPUSaysNothing() {
        let pkt = Self.avccPacket([Self.hevcNAL(type: 62, payload: [0x00])])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == nil)
    }

    @Test("an RPU the guard rejects is never handed to libdovi, which would abort the process")
    func rpuThatWouldAbortLibdoviSaysNothing() {
        let rpu = DoviRpuGuardTests.craft(linearOnComponent: 1)
        let pkt = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), rpu])
        defer { Self.free(pkt) }
        #expect(DolbyVisionRecordAudit.rpuProfile(pkt) == nil)
    }

    // MARK: - When the RPU is worth reading

    @Test("a Profile 5 record over a BT.2020 YCbCr PQ VUI is worth auditing")
    func profile5OverHDR10VUIIsAudited() {
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("a Profile 5 record over an HLG VUI is worth auditing too")
    func profile5OverHLGVUIIsAudited() {
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_ARIB_STD_B67, colorMatrix: AVCOL_SPC_BT2020_CL))
    }

    @Test("a genuine Profile 5 is never read, so it costs no packet")
    func genuineProfile5IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5,
            colorTransfer: AVCOL_TRC_UNSPECIFIED, colorMatrix: AVCOL_SPC_UNSPECIFIED))
    }

    @Test("a record that agrees with its VUI is not a contradiction")
    func profile81IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 8,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("AV1 Profile 10.0 is out of scope: its RPU is not in an unspec62 NAL")
    func av1IsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_AV1, dvProfile: 10,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    @Test("a source with no Dolby Vision record is not audited")
    func nonDVIsNotAudited() {
        #expect(!DolbyVisionRecordAudit.recordIsContradicted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: nil,
            colorTransfer: AVCOL_TRC_SMPTE2084, colorMatrix: AVCOL_SPC_BT2020_NCL))
    }

    // MARK: - The verdict

    @Test("a Profile 5 record over a Profile 7 RPU is corrected to 7")
    func recordFiveRPUSevenCorrectsToSeven() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 7) == 7)
    }

    @Test("a Profile 5 record over a Profile 8 RPU is corrected to 8")
    func recordFiveRPUEightCorrectsToEight() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 8) == 8)
    }

    @Test("an RPU that agrees with the record corrects nothing")
    func agreeingRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 5) == nil)
    }

    @Test("no readable RPU leaves the record standing")
    func unreadRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: nil) == nil)
    }

    @Test("an RPU libdovi could not classify is not a profile to route on")
    func unclassifiedRPUCorrectsNothing() {
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 0) == nil)
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: 4) == nil)
    }

    // MARK: - The route the verdict buys

    /// An `AVCodecParameters` carrying a DOVI record and a VUI, freed with the test.
    private final class DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>
        init(profile: UInt8, blCompatibilityID: UInt8,
             trc: AVColorTransferCharacteristic = AVCOL_TRC_SMPTE2084,
             matrix: AVColorSpace = AVCOL_SPC_BT2020_NCL) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_HEVC
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.level = 153
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = trc
            ptr.pointee.color_space = matrix
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            guard let sd = av_packet_side_data_new(
                &ptr.pointee.coded_side_data, &ptr.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF, size, 0) else {
                fatalError("could not attach a DOVI configuration record")
            }
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_profile = profile
                rec.pointee.dv_level = 6
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
            }
        }
        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(
        _ par: DVCodecpar, dvDisplay: Bool = true, rpuProfile: Int?,
        handling: DolbyVisionHandling = .automatic
    ) throws -> HLSVideoEngine.CodecRoute {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/dev/null"),
            dvModeAvailable: dvDisplay,
            dolbyVisionHandling: handling,
            dolbyVisionRPUProfile: rpuProfile)
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    /// The reported shape: a Profile 5 record over an HDR10 VUI.
    private static func relabelledProfile5() -> DVCodecpar {
        DVCodecpar(profile: 5, blCompatibilityID: 0)
    }

    @Test("a Profile 5 record whose RPU is a Profile 8 is served as Profile 8.1")
    func relabelledEightRoutesAs81() throws {
        let r = try Self.route(Self.relabelledProfile5(), rpuProfile: 8)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        // The record said compatibility 0; the rewrite writes the 8.1 it should have carried.
        #expect(r.doviConfig == .rewriteToProfile81)
        #expect(r.convertP7ToProfile81 == false)
        #expect(r.dvVariant == .profile81)
    }

    @Test("a Profile 5 record whose RPU is a Profile 7 gets the Profile 7 conversion")
    func relabelledSevenRoutesAsP7() throws {
        let r = try Self.route(Self.relabelledProfile5(), rpuProfile: 7)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        #expect(r.doviConfig == .rewriteToProfile81)
        #expect(r.convertP7ToProfile81)
        #expect(r.dvVariant == .profile7)
    }

    @Test("the same correction on a display without Dolby Vision is converted and served as 8.1 too")
    func relabelledSevenOnNonDVDisplay() throws {
        let r = try Self.route(Self.relabelledProfile5(), dvDisplay: false, rpuProfile: 7)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.videoRange == .pq)
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        #expect(r.doviConfig == .rewriteToProfile81)
        #expect(r.convertP7ToProfile81)
    }

    @Test("without a verdict the record stands and the route does not move")
    func noVerdictKeepsProfile5Route() throws {
        let r = try Self.route(Self.relabelledProfile5(), rpuProfile: nil)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.dvVariant == .profile5)
    }

    @Test("an RPU that agrees with the record moves nothing")
    func agreeingRPUKeepsProfile5Route() throws {
        let r = try Self.route(Self.relabelledProfile5(), rpuProfile: 5)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.dvVariant == .profile5)
    }

    @Test("a host asking for the base layer still gets the base layer")
    func baseLayerOnlyWinsOverTheCorrection() throws {
        let r = try Self.route(Self.relabelledProfile5(), rpuProfile: 7, handling: .baseLayerOnly)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .strip)
        #expect(r.convertP7ToProfile81 == false)
    }

    @Test("the RPU walk ends on foreign packets and bytes, not only on video packets")
    func walkIsBoundedByEveryPacket() {
        #expect(!DolbyVisionRecordAudit.walkExhausted(packetsRead: 63, bytesRead: 0, packetBudget: 4))
        #expect(DolbyVisionRecordAudit.walkExhausted(packetsRead: 64, bytesRead: 0, packetBudget: 4))
        #expect(DolbyVisionRecordAudit.walkExhausted(
            packetsRead: 1, bytesRead: DolbyVisionRecordAudit.walkByteBudget, packetBudget: 4))
        #expect(!DolbyVisionRecordAudit.walkExhausted(packetsRead: 1, bytesRead: 0, packetBudget: Int.max))
    }

    // MARK: - Against real media

    @Test("the relabelled fixture's RPU reports the profile its record hides",
          .enabled(if: relabelledFixtureExists(), "see relabelledFixtureURL for the two-byte recipe"))
    func relabelledFixtureRPUSaysEight() throws {
        #expect(DolbyVisionRecordAudit.rpuProfileOfSource(
            url: relabelledFixtureURL(), extraHeaders: [:]) == 8)
    }

    @Test("a genuine Profile 5 asset's RPU agrees with its record, so nothing is corrected",
          .enabled(if: genuineProfile5FixtureExists(), "see genuineProfile5FixtureURL for the download"))
    func genuineFixtureRPUSaysFive() throws {
        let rpu = DolbyVisionRecordAudit.rpuProfileOfSource(
            url: genuineProfile5FixtureURL(), extraHeaders: [:])
        #expect(rpu == 5)
        #expect(DolbyVisionRecordAudit.correctedProfile(record: 5, rpu: rpu) == nil)
    }

    @Test("the one-call verdict reads a contradicted source and says what the RPU says",
          .enabled(if: relabelledFixtureExists(), "see relabelledFixtureURL for the two-byte recipe"))
    func verdictForRelabelledSource() throws {
        #expect(DolbyVisionRecordAudit.rpuCorrection(url: relabelledFixtureURL()) == 8)
    }

    @Test("the one-call verdict leaves an uncontradicted source alone",
          .enabled(if: genuineProfile5FixtureExists(), "see genuineProfile5FixtureURL for the download"))
    func verdictForGenuineSource() throws {
        #expect(DolbyVisionRecordAudit.rpuCorrection(url: genuineProfile5FixtureURL()) == nil)
    }

    // MARK: - A Profile 5 the container never recorded

    private static func candidate(
        codec: AVCodecID = AV_CODEC_ID_HEVC, hasRecord: Bool = false,
        pixelFormat: AVPixelFormat = AV_PIX_FMT_YUV420P10LE,
        trc: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
        matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED,
        primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED
    ) -> Bool {
        DolbyVisionRecordAudit.recordlessProfile5IsCandidate(
            codecID: codec, hasRecord: hasRecord, pixelFormat: pixelFormat.rawValue,
            colorTransfer: trc, colorMatrix: matrix, colorPrimaries: primaries)
    }

    @Test("untagged 10-bit HEVC with no record is worth reading")
    func untaggedTenBitHEVCIsACandidate() {
        #expect(Self.candidate())
    }

    @Test("a source that has a record is never a candidate")
    func recordedSourceIsNotACandidate() {
        #expect(!Self.candidate(hasRecord: true))
    }

    @Test("a source that names any colour description is never a candidate")
    func describedSourceIsNotACandidate() {
        #expect(!Self.candidate(trc: AVCOL_TRC_SMPTE2084))
        #expect(!Self.candidate(trc: AVCOL_TRC_BT709))
        #expect(!Self.candidate(matrix: AVCOL_SPC_BT2020_NCL))
        #expect(!Self.candidate(matrix: AVCOL_SPC_BT709))
        #expect(!Self.candidate(primaries: AVCOL_PRI_BT2020))
    }

    @Test("8-bit and non-HEVC sources are never candidates")
    func otherFormatsAreNotCandidates() {
        #expect(!Self.candidate(pixelFormat: AV_PIX_FMT_YUV420P))
        #expect(!Self.candidate(pixelFormat: AV_PIX_FMT_YUV420P12LE))
        #expect(!Self.candidate(codec: AV_CODEC_ID_H264))
        #expect(!Self.candidate(codec: AV_CODEC_ID_AV1))
    }

    @Test("only an RPU that reads profile 5 proves it")
    func onlyProfile5IsProof() {
        #expect(DolbyVisionRecordAudit.rpuProvesProfile5(5))
        #expect(!DolbyVisionRecordAudit.rpuProvesProfile5(8))
        #expect(!DolbyVisionRecordAudit.rpuProvesProfile5(7))
        #expect(!DolbyVisionRecordAudit.rpuProvesProfile5(nil))
    }

    @Test("a real Profile 5 RPU proves a candidate, a Profile 8.1 RPU does not")
    func realRPUsDecideTheCandidate() {
        let five = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.genuineProfile5RPU)])
        let eight = Self.avccPacket([Self.hevcNAL(type: 1, payload: [0xAA]), Self.bytes(Self.realProfile81RPU)])
        defer { Self.free(five); Self.free(eight) }
        #expect(DolbyVisionRecordAudit.rpuProvesProfile5(DolbyVisionRecordAudit.rpuProfile(five)))
        #expect(!DolbyVisionRecordAudit.rpuProvesProfile5(DolbyVisionRecordAudit.rpuProfile(eight)))
    }

    @Test("the synthesized record reads back as Profile 5, compatibility 0, level 6")
    func synthesizedRecordIsAGenuineProfile5() throws {
        let par = try #require(avcodec_parameters_alloc())
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        #expect(DolbyVisionRecordAudit.synthesizeProfile5Record(par))
        let item = try #require(par.pointee.coded_side_data)
        #expect(par.pointee.nb_coded_side_data == 1)
        #expect(item[0].type == AV_PKT_DATA_DOVI_CONF)
        let rec = item[0].data!.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        #expect(rec.dv_version_major == 1 && rec.dv_version_minor == 0)
        #expect(rec.dv_profile == 5 && rec.dv_level == 6)
        #expect(rec.rpu_present_flag == 1 && rec.el_present_flag == 0 && rec.bl_present_flag == 1)
        #expect(rec.dv_bl_signal_compatibility_id == 0)
    }
}

// MARK: - Fixtures

/// A Profile 8.1 remux whose container record was relabelled to Profile 5 / compatibility 0, which is
/// the reported shape: the record claims IPT-PQ-c2 while the VUI and the RPU describe an HDR10 base.
/// Nothing can be committed here, so build it from Dolby's own Profile 8.1 test signal
/// (see `reference` in `genuineProfile5FixtureURL`) by flipping two bytes of its `dvvC` box:
///
///     python3 -c "
///     d=bytearray(open('Patterns_Of_Nature_HDR10-P8.1_UHD_24_H265-10Mbps_DD+JOC-768Kbps.mp4','rb').read())
///     p=d.find(b'dvvC')+4
///     d[p+2]=(5<<1)|(d[p+2]&1)   # dv_profile 8 -> 5
///     d[p+4]=d[p+4]&0x0F         # dv_bl_signal_compatibility_id 1 -> 0
///     open('Fixtures/user/dv-p5-relabelled-synthetic.mp4','wb').write(bytes(d))"
///
/// The bitstream is untouched, so the RPU underneath still reports profile 8 and the correction has
/// something true to find.
private func relabelledFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/user/dv-p5-relabelled-synthetic.mp4")
}

private func relabelledFixtureExists() -> Bool {
    FileManager.default.fileExists(atPath: relabelledFixtureURL().path)
}

/// Dolby's own Profile 5 signal, the negative control: a real IPT-PQ-c2 source whose VUI is unspecified
/// and whose RPU says 5. From the browser test kit, no login:
/// `https://ott.dolby.com/browser_test_kit/source_mp4s/24fps.zip`
private func genuineProfile5FixtureURL() -> URL {
    relabelledFixtureURL().deletingLastPathComponent()
        .appendingPathComponent("Patterns_Of_Nature_DoVi_24_P5_UHD_HEVC-10mbps_DD+JOC-768kbps_iOS.mp4")
}

private func genuineProfile5FixtureExists() -> Bool {
    FileManager.default.fileExists(atPath: genuineProfile5FixtureURL().path)
}

// The same real RPUs above, remuxed into tiny synthetic media, exercise the custom source's actual
// demux/open path without depending on optional downloaded fixtures or a decoder/display.
extension DolbyVisionRecordAuditTests {
    private final class AuditReader: IOReader, @unchecked Sendable {
        let playback: ProbeRecordingReader
        private let independent: @Sendable () -> IOReader?
        private let seekable: Bool
        private let clones = ProbeTestBox(0)
        var cloneCount: Int { clones.value }
        let discImageProbeEnabled = false

        init(data: Data, seekable: Bool = true, independent: @escaping @Sendable () -> IOReader?) {
            playback = ProbeRecordingReader(data: data)
            self.seekable = seekable
            self.independent = independent
        }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            playback.read(buffer, size: size)
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            seekable ? playback.seek(offset: offset, whence: whence) : -1
        }
        func cancel() { playback.cancel() }
        func close() { playback.close() }
        func makeIndependentReader() -> IOReader? {
            clones.update { $0 += 1 }
            return independent()
        }
        func makeIndependentReader(limits: ProbeLimits) -> IOReader? { makeIndependentReader() }
    }

    // Existing 64x64 HDR10 fixture, with only its SPS colour description set to unspecified by
    // hevc_metadata=colour_primaries=2:transfer_characteristics=2:matrix_coefficients=2.
    // The mux below also clears container colour fields, so stream analysis sees the recordless gate.
    private static let unspecifiedHEVC = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAALm1kYXQAAAAOKAGveOuu+//8
    W2VfLTwAAAAQKAGvCeAkBMh//ydhHsNI/AAAA8Ftb292AAAAbG12aGQAAAAAAAAAAAAAAAAAEk+AAAOpg
    AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAACAAAC7HRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAA
    AAOpgAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAA
    QAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQADqYAAAAAAAAEAAAAAAmRtZGlhAAAAIG1kaGQA
    AAAAAAAAAAAAAAAAEk+AAAOpgFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVv
    SGFuZGxlcgAAAAIPbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAAB
    AAAADHVybCAAAAABAAABz3N0YmwAAAFjc3RzZAAAAAAAAAABAAABU2h2YzEAAAAAAAAAAQAAAAAAAAAA
    AAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY
    //8AAADGaHZjQwEECAAAAJ2oAAAAAB7wAPz9+voAAA8DoAACABdAAQwB//8ECAAAAwCdqAAAAwAA
    HroCQAAXQAEMAf//BAgAAAMAnagAAAMAAB66AkChAAIAK0IBAQQIAAADAJ2oAAADAAAeoCCBBNlupJMr
    wFqBAQECAAADAAIAAAMAFBAAK0IBAQQIAAADAJ2oAAADAAAeoCCBBNlupJMrwFqBAQECAAADAAIAAAMA
    FBCiAAIAB0QBwXKwIkAAB0QBwXKwIkAAAAATY29scm5jbHgACQAQAAkAAAAAEHBhc3AAAAABAAAA
    AQAAABRidHJ0AAAAAAAABfAAAAXwAAAAGHN0dHMAAAAAAAAAAQAAAAIAAdTAAAAAHHN0c2MAAAAAAAAA
    AQAAAAEAAAACAAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAEgAAABQAAAAUc3RjbwAAAAAAAAABAAAA
    LAAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3Q
    AAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI=
    """

    private static func customFixture(
        rpu: [UInt8]?, record: Bool = false, unspecified: Bool = false, leadingPackets: Int = 0
    ) throws -> Data {
        let input = try ProbeTestFixtures.decode(
            unspecified ? unspecifiedHEVC : HDR10PlusProbeIntegrationTests.hdr10Base64)
        let source = Demuxer()
        defer { source.close() }
        try source.open(reader: DataIOReader(data: input), formatHint: "mp4")
        let stream = try #require(source.stream(at: source.videoStreamIndex))
        let first = try #require(try source.readPacket())
        var owned: UnsafeMutablePointer<AVPacket>? = first
        defer { av_packet_free(&owned) }

        var output: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0)
        let context = try #require(output)
        defer { avformat_free_context(context) }
        var io: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&io) >= 0)
        let buffer = try #require(io)
        context.pointee.pb = buffer
        context.pointee.strict_std_compliance = -2
        var bytes: UnsafeMutablePointer<UInt8>?
        var closed = false
        defer {
            if !closed { _ = avio_close_dyn_buf(buffer, &bytes) }
            av_free(bytes)
        }
        let target = try #require(avformat_new_stream(context, nil))
        let codecpar = try #require(target.pointee.codecpar)
        try #require(avcodec_parameters_copy(codecpar, stream.pointee.codecpar) >= 0)
        if unspecified {
            codecpar.pointee.color_primaries = AVCOL_PRI_UNSPECIFIED
            codecpar.pointee.color_trc = AVCOL_TRC_UNSPECIFIED
            codecpar.pointee.color_space = AVCOL_SPC_UNSPECIFIED
        }
        if record { try #require(DolbyVisionRecordAudit.synthesizeProfile5Record(codecpar)) }
        target.pointee.time_base = stream.pointee.time_base
        try #require(avformat_write_header(context, nil) >= 0)
        for index in 0...leadingPackets {
            var packet: UnsafeMutablePointer<AVPacket>? = av_packet_clone(first)
            defer { av_packet_free(&packet) }
            let copy = try #require(packet)
            if index == leadingPackets, let rpu {
                let original = Int(copy.pointee.size)
                try #require(av_grow_packet(copy, Int32(rpu.count + 4)) >= 0)
                var nal = withUnsafeBytes(of: UInt32(rpu.count).bigEndian) { Array($0) }
                nal += rpu
                nal.withUnsafeBytes { raw in
                    _ = memcpy(copy.pointee.data + original, raw.baseAddress, nal.count)
                }
            }
            copy.pointee.pts = Int64(index) * 7500
            copy.pointee.dts = copy.pointee.pts
            copy.pointee.duration = 7500
            av_packet_rescale_ts(copy, stream.pointee.time_base, target.pointee.time_base)
            copy.pointee.stream_index = 0
            copy.pointee.pos = -1
            try #require(av_interleaved_write_frame(context, copy) >= 0)
        }
        try #require(av_write_trailer(context) >= 0)
        let count = avio_close_dyn_buf(buffer, &bytes)
        closed = true
        context.pointee.pb = nil
        try #require(count > 0)
        return Data(bytes: try #require(bytes), count: Int(count))
    }

    @Test("custom recordless P5 is repaired without consuming the playback packet")
    func customRecordlessP5IsRepaired() throws {
        let data = try Self.customFixture(rpu: Self.bytes(Self.genuineProfile5RPU), unspecified: true)
        let clone = ProbeRecordingReader(data: data)
        let reader = AuditReader(data: data) { clone }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(AetherEngine.dvConfig(stream: stream)?.profile == 5)
        #expect(reader.cloneCount == 1)
        #expect(clone.closeCount == 1)
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
        let packet = try #require(try demuxer.readPacket())
        defer { Self.free(packet) }
        #expect(DolbyVisionRecordAudit.rpuProfile(packet) == 5)
        #expect(packet.pointee.pts == 0)
    }

    @Test("a recorded P5 custom source keeps its record and does not create an audit cursor")
    func customRecordedP5IsUnchanged() throws {
        let data = try Self.customFixture(
            rpu: Self.bytes(Self.genuineProfile5RPU), record: true, unspecified: true)
        let reader = AuditReader(data: data) { nil }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(AetherEngine.dvConfig(stream: stream)?.profile == 5)
        #expect(reader.cloneCount == 0)
    }

    @Test("contradictory custom P5 records follow the parsed P7/P8 RPU", arguments: [7, 8])
    func customContradictoryRecordIsCorrected(profile: Int) throws {
        let nal = profile == 7
            ? DoviRpuGuardTests.craft(pieces: Array(repeating: [.polynomial], count: 3), residual: .mel)
            : Self.bytes(Self.realProfile81RPU)
        let data = try Self.customFixture(rpu: nal, record: true)
        let clone = ProbeRecordingReader(data: data)
        let reader = AuditReader(data: data) { clone }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let record = AetherEngine.dvConfig(stream: stream)?.profile
        #expect(record == 5)
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: stream.pointee.codecpar.pointee.codec_id, dvProfile: record,
            colorTransfer: stream.pointee.codecpar.pointee.color_trc,
            colorMatrix: stream.pointee.codecpar.pointee.color_space))
        let reads = reader.playback.reads.count
        let seeks = reader.playback.seeks.count
        let parsed = demuxer.dolbyVisionRPUProfile()
        #expect(parsed == profile)
        #expect(DolbyVisionRecordAudit.correctedProfile(record: record, rpu: parsed) == profile)
        let route = try Self.route(Self.relabelledProfile5(), rpuProfile: parsed)
        #expect(route.doviConfig == .rewriteToProfile81)
        #expect(route.convertP7ToProfile81 == (profile == 7))
        #expect(reader.playback.reads.count == reads)
        #expect(reader.playback.seeks.count == seeks)
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
        #expect(clone.closeCount == 1)
    }

    @Test("missing or malformed custom RPU never invents DV", arguments: [false, true])
    func customUnreadableRPULeavesRecordAlone(malformed: Bool) throws {
        let data = try Self.customFixture(rpu: malformed ? [0x7C, 1, 0] : nil, unspecified: true)
        let clone = ProbeRecordingReader(data: data)
        let reader = AuditReader(data: data) { clone }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(AetherEngine.dvConfig(stream: stream) == nil)
        #expect(reader.cloneCount == 1)
        #expect(clone.closeCount == 1)
    }

    @Test("live and nonseekable custom inputs never request an independent cursor", arguments: [false, true])
    func customIneligibleSourceIsSkipped(live: Bool) throws {
        let data = try Self.customFixture(rpu: Self.bytes(Self.genuineProfile5RPU), unspecified: true)
        let reader = AuditReader(data: data, seekable: live) { nil }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4", isLive: live)
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(AetherEngine.dvConfig(stream: stream) == nil)
        #expect(demuxer.dolbyVisionRPUProfile() == nil)
        #expect(reader.cloneCount == 0)
    }

    @Test("a missing, nonseekable or failing audit cursor leaves playback alone", arguments: [0, 1, 2])
    func customUnavailableCursorIsSkipped(kind: Int) throws {
        let data = try Self.customFixture(rpu: Self.bytes(Self.genuineProfile5RPU), unspecified: true)
        let clone = ProbeRecordingReader(data: Data())
        let nonseekable = AuditReader(data: data, seekable: false) { nil }
        let reader = AuditReader(data: data) {
            if kind == 0 { return nil }
            if kind == 1 { return nonseekable }
            return clone
        }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        #expect(AetherEngine.dvConfig(stream: stream) == nil)
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
        let packet = try #require(try demuxer.readPacket())
        defer { Self.free(packet) }
        #expect(DolbyVisionRecordAudit.rpuProfile(packet) == 5)
        if kind == 1 { #expect(nonseekable.playback.closeCount == 1) }
        if kind == 2 { #expect(clone.closeCount == 1) }
    }

    @Test("a clone factory returning playback itself cannot move or close playback")
    func customSameCursorIsRejected() {
        let holder = ProbeTestBox<IOReader?>(nil)
        let reader = AuditReader(data: Data()) { holder.value }
        holder.update { $0 = reader }
        defer { holder.update { $0 = nil } }
        let parsed = DolbyVisionRecordAudit.rpuProfileOfSource(reader: reader)
        #expect(parsed == nil)
        #expect(reader.playback.reads.isEmpty)
        #expect(reader.playback.seeks.isEmpty)
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
    }

    @Test("cancellation wins over bytes containing a valid custom RPU", arguments: [false, true])
    func customCancelledPositiveIsDiscarded(beforeOpen: Bool) throws {
        let data = try Self.customFixture(rpu: Self.bytes(Self.genuineProfile5RPU), unspecified: true)
        let cancellation = ProbeCancellation()
        let clone = ProbeRecordingReader(data: data, afterRead: { cancellation.cancel() })
        let reader = AuditReader(data: data) { clone }
        if beforeOpen { cancellation.cancel() }
        let parsed = DolbyVisionRecordAudit.rpuProfileOfSource(
            reader: reader, formatHint: "mp4", cancellation: cancellation)
        #expect(parsed == nil)
        #expect(reader.cloneCount == (beforeOpen ? 0 : 1))
        #expect(clone.closeCount == (beforeOpen ? 0 : 1))
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
    }

    @Test("custom audit honours both video packet budgets", arguments: [4, 16])
    func customPacketBudgetIsKept(budget: Int) throws {
        for leading in [budget - 1, budget] {
            let data = try Self.customFixture(rpu: Self.bytes(Self.realProfile81RPU), leadingPackets: leading)
            let clone = ProbeRecordingReader(data: data)
            let reader = AuditReader(data: data) { clone }
            let parsed = DolbyVisionRecordAudit.rpuProfileOfSource(
                reader: reader, formatHint: "mp4", packetBudget: budget)
            let expected: Int? = leading < budget ? 8 : nil
            #expect(parsed == expected)
            #expect(reader.playback.reads.isEmpty)
            #expect(reader.playback.seeks.isEmpty)
            #expect(clone.closeCount == 1)
        }
    }

    @Test("audit cancellation interrupts only the clone and joins its callback", .timeLimit(.minutes(1)),
          arguments: ProbeParkedReader.Operation.allCases)
    func customCancellationDoesNotTouchPlayback(operation: ProbeParkedReader.Operation) async throws {
        let clone = ProbeParkedReader(operation: operation)
        defer { clone.release() }
        let reader = AuditReader(data: Data()) { clone }
        let cancellation = ProbeCancellation()
        let job = ProbeTestJob {
            DolbyVisionRecordAudit.rpuProfileOfSource(
                reader: reader, formatHint: "mp4", cancellation: cancellation)
        }
        try await waitFor { clone.interrupted.entered }
        cancellation.cancel()
        #expect(clone.cancelCount == 1)
        #expect(!job.isFinished)
        clone.mayReturn.open()
        let result = try await job.outcome().get()
        #expect(result == nil)
        #expect(clone.closeCount == 1)
        #expect(reader.playback.reads.isEmpty)
        #expect(reader.playback.seeks.isEmpty)
        #expect(reader.playback.cancelCount == 0)
        #expect(reader.playback.closeCount == 0)
    }

    @Test("a custom audit's watchdog interrupts a read that never answers", .timeLimit(.minutes(1)))
    func customAuditDeadlineUnblocksItsCursor() async throws {
        let clone = ProbeParkedReader(operation: .read)
        clone.mayReturn.open()
        defer { clone.release() }
        let reader = AuditReader(data: Data()) { clone }
        // test-wait: this exercises the real DispatchSource watchdog waking cooperative blocked I/O.
        let job = ProbeTestJob {
            DolbyVisionRecordAudit.rpuProfileOfSource(reader: reader, formatHint: "mp4", timeBudget: 0.05)
        }
        // The deadline itself is the assertion; release even a broken arm before joining its worker.
        let finishedByDeadline = try await waitFor(upTo: .seconds(2)) { job.isFinished }
        #expect(finishedByDeadline)
        clone.release()
        let result = try await job.outcome().get()
        #expect(result == nil)
        #expect(clone.cancelCount == 1)
        #expect(clone.closeCount == 1)
        #expect(reader.playback.cancelCount == 0)
    }

    @Test("closing the parent demuxer cancels its independent audit", .timeLimit(.minutes(1)))
    func closingParentCancelsCustomAudit() async throws {
        let data = try Self.customFixture(rpu: Self.bytes(Self.realProfile81RPU), record: true)
        let clone = ProbeParkedReader(operation: .read)
        defer { clone.release() }
        let reader = AuditReader(data: data) { clone }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: reader, formatHint: "mp4")
        let job = ProbeTestJob { demuxer.dolbyVisionRPUProfile() }
        try await waitFor { clone.interrupted.entered }
        demuxer.markClosed()
        #expect(clone.cancelCount == 1)
        #expect(!job.isFinished)
        clone.mayReturn.open()
        let result = try await job.outcome().get()
        #expect(result == nil)
        #expect(clone.closeCount == 1)
    }
}
