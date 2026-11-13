import AVFoundation
import Testing
@testable import AetherEngine

/// AetherEngine#39's speed ceiling, per route (W2424). Above 2x AVPlayer stops playing an HLS stream frame by
/// frame, so the two AVPlayer HLS routes (loopback, remote-HLS) stay at 2x; the software route (its own renderer)
/// and the audio-only one (no frames to skip) go to 3x. These pin each route's value, that the live ceiling
/// follows the host the engine drives, and that a speed carried into a rebuilt native host is cut to its ceiling.
@Suite("AetherEngine#39: speed ceiling per route")
@MainActor
struct VideoRateCeilingTests {

    @Test("each route's ceiling: 2x on the AVPlayer HLS routes, 3x on software and audio-only")
    func ceilingPerRoute() {
        #expect(AetherEngine.maxSupportedRate(on: .loopback) == 2.0)
        #expect(AetherEngine.maxSupportedRate(on: .remoteBypass) == 2.0)
        #expect(AetherEngine.maxSupportedRate(on: .software) == 3.0)
        #expect(AetherEngine.maxSupportedRate(on: .audio) == 3.0)
        #expect(AetherEngine.maxSupportedRate(on: .none) == 2.0)
    }

    @Test("on the native video host 2.5x and 3x are clamped to 2x")
    func nativeHostIsClampedToTwo() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        #expect(engine.maxSupportedRate == 2.0)

        engine.setRate(2.0)
        #expect(host.avPlayer.defaultRate == 2.0)

        engine.setRate(2.5)
        #expect(host.avPlayer.defaultRate == 2.0)
        #expect(engine.desiredRate == 2.0)

        engine.setRate(3.0)
        #expect(host.avPlayer.defaultRate == 2.0)
        #expect(engine.desiredRate == 2.0)
    }

    @Test("the software and audio-only hosts reach 3x")
    func softwareAndAudioReachThree() throws {
        let software = try AetherEngine()
        software.softwareHost = SoftwarePlaybackHost()
        #expect(software.maxSupportedRate == 3.0)
        software.setRate(3.0)
        #expect(software.desiredRate == 3.0)

        let audio = try AetherEngine()
        audio.audioHost = AudioPlaybackHost()
        #expect(audio.maxSupportedRate == 3.0)

        let audioAVPlayer = try AetherEngine()
        audioAVPlayer.audioAVPlayerActive = true
        #expect(audioAVPlayer.maxSupportedRate == 3.0)
    }

    @Test("a 3x speed carried into a rebuilt native host is seeded at 2x, without playing")
    func rebuiltNativeHostIsCutToTwo() throws {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        engine.desiredRate = 3.0
        engine.applyDesiredRate(to: host)
        #expect(host.avPlayer.defaultRate == 2.0)
        #expect(host.avPlayer.rate == 0, "seeding must not start playback")
    }
}
