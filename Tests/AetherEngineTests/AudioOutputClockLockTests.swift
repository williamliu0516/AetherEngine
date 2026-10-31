import Foundation
import CoreMedia
import Testing
@testable import AetherEngine

/// A clock write can wait in the synchronizer for as long as the audio queue's prime takes (the iOS 27
/// simulator's never returned). `seekClock` made it holding `lock`, which `stop()` takes, and a recovery's stop
/// on the main thread waited behind it for good: the player froze (2026-10-31). The writes now run outside
/// `lock`, one at a time in the order asked, and a stop never waits for one: the write under way pays its rest.
@Suite("AudioOutput clock writes and stop")
struct AudioOutputClockLockTests {

    /// A write held in the synchronizer until `release` is signalled; `entered` once it is there.
    private func holdingWrites(_ output: AudioOutput) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = FirstTake()
        output.whileSettingClockForTesting = {
            guard first.take() else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        return (entered, release)
    }

    @Test("a stop returns while a seek's clock write waits in the synchronizer, and the clock ends at rest")
    func stopDoesNotWaitForASeek() {
        let output = AudioOutput()
        let (entered, release) = holdingWrites(output)
        let seeked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
            seeked.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.stop()
            stopped.signal()
        }
        // Before: the stop waited on `lock` until the seek's write came back, here 10 s.
        #expect(stopped.wait(timeout: .now() + 2) == .success)
        release.signal()
        #expect(seeked.wait(timeout: .now() + 5) == .success)
        #expect(output.rate == 0)
    }

    @Test("a pause asked while a seek's clock write waits comes after it: the clock ends paused")
    func pauseKeepsItsOrder() {
        let output = AudioOutput()
        let (entered, release) = holdingWrites(output)
        let seeked = DispatchSemaphore(value: 0), paused = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
            seeked.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            output.pause()
            paused.signal()
        }
        // The pause waits behind the seek's write, as it waited on `lock` before.
        #expect(paused.wait(timeout: .now() + 0.3) == .timedOut)
        release.signal()
        #expect(seeked.wait(timeout: .now() + 5) == .success)
        #expect(paused.wait(timeout: .now() + 5) == .success)
        #expect(output.rate == 0)
    }
}

/// True for the first `take()` only.
private final class FirstTake: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
