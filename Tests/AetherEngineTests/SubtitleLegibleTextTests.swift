import Testing
@testable import AetherEngine

@Suite("Selected AVPlayer subtitle text")
@MainActor struct SubtitleLegibleTextTests {
    @Test func earlyMissingOrEmptyGroupIsRetriedAfterReadiness() async throws {
        for early: [Int]? in [nil, []] {
            var loads = 0, waited = false
            let group = await RemoteHLSMediaSelection.legibleGroup(load: {
                loads += 1
                if loads == 1 { return early }
                #expect(waited)
                return [200_000]
            }, isEmpty: { $0.isEmpty }, waitUntilReady: { waited = true })
            #expect(group == [200_000])
            #expect(loads == 2)
            #expect(waited)
        }
        var waited = false
        let group = await RemoteHLSMediaSelection.legibleGroup(load: { [200_000] },
                                                               isEmpty: { $0.isEmpty },
                                                               waitUntilReady: { waited = true })
        #expect(group == [200_000])
        #expect(!waited)
    }

    @Test func injectedRenditionKeepsItsExternalIdentityAndDeliversNativeWords() throws {
        let origin = RemoteHLSMediaSelection.LegibleOption(displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false, playlistName: "Origin")
        let injected = RemoteHLSMediaSelection.LegibleOption(displayName: "German", extendedLanguageTag: "de",
            isDefault: false, isForced: false, isSDH: false, playlistName: "DE")
        let externalID = AetherEngine.externalSubtitleTrackIDBase
        let declared = [TrackInfo(id: externalID, name: "Sidecar", codec: "srt", language: "de",
                                  isDefault: false, isExternal: true),
                        TrackInfo(id: externalID + 1, name: "Bitmap", codec: "pgssub", language: "de",
                                  isDefault: false, isExternal: true)]
        let names = [externalID: "DE"]
        let tracks = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: declared, legible: [origin, injected],
                                                                  injectedRenditions: names)
        let ids = RemoteHLSMediaSelection.trackIDs(from: [origin, injected], injectedRenditions: names)
        #expect(ids == [200_000, externalID])
        #expect(tracks.map(\.id) == [externalID, externalID + 1, 200_000])
        #expect(tracks.first?.isNativelyRenderedSubtitle == true)
        #expect(tracks[1].isNativelyRenderedSubtitle == false)
        let engine = try AetherEngine()
        engine.activeSubtitleTrackIndex = externalID
        engine.receiveLegibleSubtitle(["Injected words"], at: 10, trackID: ids[1])
        #expect(engine.legibleSubtitleCues.first?.text == "Injected words")
        engine.receiveLegibleSubtitle([], at: 12, trackID: ids[1])
        #expect(engine.legibleSubtitleCues.first?.endTime == 12)
    }

    @Test func wordsCloseOnReplacementAndClearWithoutGuessingAnEnd() throws {
        let engine = try AetherEngine()
        engine.activeSubtitleTrackIndex = 200_000
        engine.receiveLegibleSubtitle(["Hello", "world"], at: 10, trackID: 200_000)
        #expect(engine.legibleSubtitleCues.first?.text == "Hello\nworld")
        #expect(engine.legibleSubtitleCues.first?.endTime == .infinity)
        engine.receiveLegibleSubtitle(["Next"], at: 12, trackID: 200_000)
        #expect(engine.legibleSubtitleCues.first?.endTime == 12)
        engine.receiveLegibleSubtitle([], at: 14, trackID: 200_000)
        #expect(engine.legibleSubtitleCues.last?.endTime == 14)
    }

    @Test func selectionSeekAndOldTrackCannotLeakWords() throws {
        let engine = try AetherEngine()
        engine.activeSubtitleTrackIndex = 200_000
        engine.receiveLegibleSubtitle(["Old"], at: 10, trackID: 200_000)
        engine.activeSubtitleTrackIndex = 200_001
        #expect(engine.legibleSubtitleCues.isEmpty)
        engine.receiveLegibleSubtitle(["Late old"], at: 11, trackID: 200_000)
        #expect(engine.legibleSubtitleCues.isEmpty)
        engine.receiveLegibleSubtitle(["New"], at: 11, trackID: 200_001)
        engine.clearLegibleSubtitleCues()
        #expect(engine.legibleSubtitleCues.isEmpty)
        engine.receiveLegibleSubtitle(["Bad time"], at: .nan, trackID: 200_001)
        #expect(engine.legibleSubtitleCues.isEmpty)
    }

    @Test func nativeTextWindowIsBounded() throws {
        let engine = try AetherEngine()
        engine.activeSubtitleTrackIndex = 200_000
        for i in 0..<500 { engine.receiveLegibleSubtitle(["Line \(i)"], at: Double(i) / 10, trackID: 200_000) }
        #expect(engine.legibleSubtitleCues.count == 128)
        engine.receiveLegibleSubtitle(["After gap"], at: 500, trackID: 200_000)
        #expect(engine.legibleSubtitleCues.count <= 2)
    }
}
