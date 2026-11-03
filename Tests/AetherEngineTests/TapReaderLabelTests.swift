import Testing
@testable import AetherEngine

/// The audio tap's per-segment opens name themselves (Zool, Diagnostics 73): logged as `pump`, 45 of them during
/// one seek read like the session's own demuxer reopening several times a second.
@Suite("Tap reader label")
struct TapReaderLabelTests {
    @Test func theTapOpensUnderItsOwnName() {
        let profile = AudioTapSegmentDecoder.openProfile
        #expect(profile.readerLabel == "tap")
        #expect(profile.probesize == DemuxerOpenProfile.playback.probesize)
        #expect(profile.maxAnalyzeDuration == DemuxerOpenProfile.playback.maxAnalyzeDuration)
    }
}
