import AVFoundation
import Testing
@testable import AetherEngine

/// AetherEngine#39 capped video at 2x after 3x went abnormal on an A12 iPad running iOS 16, on the native
/// route with the platform's old default pitch algorithm. Every route now pins TimeDomain (#434, range 1/32
/// to 32), so video's ceiling is raised to 3x like audio-only's (WIP, W2424: the per-route measurement is
/// not finished). These pin the ceiling on a video host and that a 3x request reaches it unclamped.
@Suite("AetherEngine#39: video plays to 3x")
@MainActor
struct VideoRateCeilingTests {

    @Test("a video session's ceiling is 3x, the same as an audio-only one's")
    func videoCeilingIsThree() throws {
        let engine = try AetherEngine()
        engine.nativeHost = NativeAVPlayerHost()
        #expect(!engine.audioAVPlayerActive && engine.audioHost == nil)
        #expect(engine.maxSupportedRate == 3.0)
    }

    @Test("3x and 2.5x reach the native video host unclamped; above 3x is clamped to 3x")
    func nativeHostGetsTheRequestedSpeed() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host

        engine.setRate(2.5)
        #expect(host.avPlayer.defaultRate == 2.5)
        #expect(engine.desiredRate == 2.5)

        engine.setRate(3.0)
        #expect(host.avPlayer.defaultRate == 3.0)
        #expect(engine.desiredRate == 3.0)

        engine.setRate(4.0)
        #expect(host.avPlayer.defaultRate == 3.0)
        #expect(engine.desiredRate == 3.0)
    }

    @Test("a 3x speed carried into a rebuilt video host is seeded at 3x, not cut to 2x")
    func rebuiltVideoHostKeepsThree() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        engine.desiredRate = 3.0
        engine.applyDesiredRate(to: host)
        #expect(host.avPlayer.defaultRate == 3.0)
        #expect(host.avPlayer.rate == 0, "seeding must not start playback")
    }
}
