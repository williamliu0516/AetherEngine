import Testing
@testable import AetherEngine

/// A session-preserving rebuild starts where the session's refusal ladder ended (Zool, M5 iPad, iPadOS 27.0.1,
/// 2026-10-19): the session played from the media playlist after every master was refused with -11868; turning
/// Boost Dialogue off rebuilt it behind the full master, AVPlayer refused it again, and the single-shot latch the
/// rebuild had carried over surfaced the refusal. The host reopened the film 4 s later.
@Suite("Session master verdict")
struct SessionMasterVerdictTests {
    typealias Decision = MasterFallbackDecision

    /// The ladder's steps teach the session; a surfaced refusal teaches it nothing new, and the recovery master
    /// never undoes a media verdict.
    @Test func refusalsTeachTheSession() {
        let untested = Decision.Verdict.untested
        #expect(untested.after(.recoveryMaster) == .recoveryMaster)
        #expect(untested.after(.mediaPlaylist) == .mediaPlaylist)
        #expect(untested.after(.surface) == .untested)
        #expect(Decision.Verdict.recoveryMaster.after(.mediaPlaylist) == .mediaPlaylist)
        #expect(Decision.Verdict.mediaPlaylist.after(.recoveryMaster) == .mediaPlaylist)
    }

    /// Boost Dialogue, Volume Boost, the audio pick and a route change rebuild the session and keep the verdict; a
    /// new load (another film, the host's reopen) asks AVPlayer again.
    @Test func rebuildsKeepItNewLoadsAskAgain() {
        #expect(Decision.Verdict.mediaPlaylist.atLoad(sessionPreserving: true) == .mediaPlaylist)
        #expect(Decision.Verdict.recoveryMaster.atLoad(sessionPreserving: true) == .recoveryMaster)
        #expect(Decision.Verdict.mediaPlaylist.atLoad(sessionPreserving: false) == .untested)
    }

    /// Diagnostics 74: the rebuild after the toggle mounts the media playlist the session settled on, not the
    /// master it already refused twice.
    @Test func aRebuildStartsWhereTheLadderEnded() {
        #expect(Decision.mount(verdict: .mediaPlaylist, servingMasterPlaylist: true, airPlayActive: false,
                               recoveryMasterDiffers: true) == .mediaPlaylist)
        #expect(Decision.mount(verdict: .recoveryMaster, servingMasterPlaylist: true, airPlayActive: false,
                               recoveryMasterDiffers: true) == .recoveryMaster)
        #expect(Decision.mount(verdict: .untested, servingMasterPlaylist: true, airPlayActive: false,
                               recoveryMasterDiffers: true) == .primary)
    }

    /// The primary where the verdict has nothing to say: a session serving the media playlist anyway, AirPlay (its
    /// receiver decision stands), and a recovery master that would drop nothing (the accepted master is the
    /// primary itself then, after Volume Boost turned object audio into PCM).
    @Test func thePrimaryWhereTheVerdictDoesNotApply() {
        #expect(Decision.mount(verdict: .mediaPlaylist, servingMasterPlaylist: false, airPlayActive: false,
                               recoveryMasterDiffers: true) == .primary)
        #expect(Decision.mount(verdict: .mediaPlaylist, servingMasterPlaylist: true, airPlayActive: true,
                               recoveryMasterDiffers: true) == .primary)
        #expect(Decision.mount(verdict: .recoveryMaster, servingMasterPlaylist: true, airPlayActive: false,
                               recoveryMasterDiffers: false) == .primary)
    }
}
