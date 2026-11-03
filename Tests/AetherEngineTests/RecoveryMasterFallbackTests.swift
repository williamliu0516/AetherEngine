import Testing
import Foundation
@testable import AetherEngine

/// A master the engine serves for a DV or HDR file with E-AC-3 and WebVTT renditions.
final class MasterFixtureProvider: HLSSegmentProvider, @unchecked Sendable {
    let range: HLSVideoRange
    let supplemental: String?
    let channels: String?
    let codecs: String
    let renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)]
    init(range: HLSVideoRange, supplemental: String?, channels: String?,
         codecs: String = "hvc1.2.4.L150.b0,ec-3",
         renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] = [(0, "eng", "English", false)]) {
        self.range = range
        self.supplemental = supplemental
        self.channels = channels
        self.codecs = codecs
        self.renditions = renditions
    }
    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { codecs }
    var masterVideoRange: HLSVideoRange? { range }
    var masterResolution: (width: Int, height: Int)? { (3840, 2160) }
    var masterFrameRate: Double? { 23.976 }
    var masterSupplementalCodecs: String? { supplemental }
    var masterAudioRendition: (language: String?, name: String)? { channels == nil ? nil : ("eng", "English") }
    var masterAudioChannels: String? { channels }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { renditions }
}

/// A refused master keeps its subtitles where it can (The Pitt, 2026-10-17, iPad in Picture in Picture): the #93
/// reload after an audio route change was refused with -11868 and the bare media playlist took the subtitles out of
/// the PiP window for the rest of the session.
@Suite("Recovery master before the media playlist")
struct RecoveryMasterFallbackTests {

    private static func step(code: Int = -11868, servingMaster: Bool = true, fellBack: Bool = false,
                             renditions: Bool = true, differs: Bool = true,
                             tried: Bool = false) -> MasterFallbackDecision.Step {
        MasterFallbackDecision.nextStep(
            errorCode: code, servingMasterPlaylist: servingMaster, alreadyFellBack: fellBack,
            renditionsServed: renditions, recoveryMasterDiffers: differs, recoveryMasterTried: tried)
    }

    @Test("a refused reload with renditions goes to the recovery master, its refusal to the media playlist")
    func chain() {
        #expect(Self.step() == .recoveryMaster)
        #expect(Self.step(tried: true) == .mediaPlaylist)
        #expect(Self.step(servingMaster: false, tried: true) == .surface)
        #expect(Self.step(fellBack: true) == .surface)
    }

    @Test("without renditions, or with nothing to drop, the media playlist comes next as before")
    func unchangedCases() {
        #expect(Self.step(renditions: false) == .mediaPlaylist)
        #expect(Self.step(differs: false) == .mediaPlaylist)
        #expect(Self.step(code: -1002) == .recoveryMaster)
        #expect(Self.step(code: -12642) == .surface)
    }

    @Test("the recovery master keeps the SUBTITLES group and drops 16/JOC and the DV SUPPLEMENTAL-CODECS")
    func recoveryMasterText() {
        let provider = MasterFixtureProvider(range: .pq, supplemental: "dvh1.08.06/db1p", channels: "16/JOC")
        let primary = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(primary.contains("CHANNELS=\"16/JOC\""))
        #expect(primary.contains("SUPPLEMENTAL-CODECS"))
        let recovery = HLSLocalServer.buildMasterPlaylistText(provider: provider, variant: .recoveryWithRenditions)
        #expect(!recovery.contains("JOC"))
        #expect(!recovery.contains("SUPPLEMENTAL-CODECS"))
        #expect(recovery.contains("TYPE=SUBTITLES"))
        #expect(recovery.contains("SUBTITLES=\"subs\""))
        #expect(recovery.contains("VIDEO-RANGE=PQ"))
        #expect(recovery.contains("TYPE=AUDIO"))

        let plain = MasterFixtureProvider(range: .sdr, supplemental: nil, channels: "6")
        #expect(HLSLocalServer.buildMasterPlaylistText(provider: plain, variant: .recoveryWithRenditions)
            .contains("CHANNELS=\"6\""), "a bed count is not object audio and stays")
    }
}
