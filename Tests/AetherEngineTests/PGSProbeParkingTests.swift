import Testing
@testable import AetherEngine
import AetherLibavcodec
import AetherLibavutil

/// A PGS track the container declares without a size sits the stream probe out (环太平洋, 32 such tracks: the probe
/// read its whole 50 MiB, 6.8 s of an A12Z iPad's start; with them parked find_stream_info took 2 to 6 ms).
struct PGSProbeParkingTests {

    @Test("only an unsized PGS subtitle is parked")
    func predicate() {
        #expect(Demuxer.pgsWaitsOnProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecType: AVMEDIA_TYPE_SUBTITLE, width: 0))
        #expect(!Demuxer.pgsWaitsOnProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecType: AVMEDIA_TYPE_SUBTITLE,
                                         width: 1920), "a declared size resolves at once")
        #expect(!Demuxer.pgsWaitsOnProbe(codecID: AV_CODEC_ID_SUBRIP, codecType: AVMEDIA_TYPE_SUBTITLE, width: 0))
        #expect(!Demuxer.pgsWaitsOnProbe(codecID: AV_CODEC_ID_DVB_SUBTITLE, codecType: AVMEDIA_TYPE_SUBTITLE, width: 0))
        #expect(!Demuxer.pgsWaitsOnProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE, codecType: AVMEDIA_TYPE_ATTACHMENT,
                                         width: 0))
    }
}
