import Foundation
import CoreMedia
import Testing
@testable import AetherEngine

/// A clock write can wait in the synchronizer for as long as the audio queue's prime takes (the iOS 27
/// simulator's never returned). Every clock write made it holding `lock`, which `stop()` takes, and a recovery's
/// stop on the main thread waited behind it for good: the player froze (2026-10-31). The writes now run outside
/// `lock`, one at a time in the order decided, and a stop never waits for one: the write under way pays its rest.
/// A write decided after a stop is the command revision's and `playbackEnabled`'s to drop.
/// The callers run on threads of their own, not the global pool, which a loaded full run left them waiting on for over
/// 5 s (zool.22, 4985 tests). A step that has to happen gets 60 s: a semaphore wait does not hear `.timeLimit`, so an
/// unbounded one would hang the run rather than fail; only the claims (0.3 s, 10 s) are tight.
@Suite("AudioOutput clock writes and stop", .offCooperativePool, .timeLimit(.minutes(2)))
struct AudioOutputClockLockTests {

    /// A write held in the synchronizer until `release` is signalled; `entered` once it is there.
    private func holdingWrites(_ output: AudioOutput) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = FirstTake()
        output.whileSettingClockForTesting = {
            guard first.take() else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 60)
        }
        return (entered, release)
    }

    @Test("a stop returns while a seek's clock write waits in the synchronizer, and the clock ends at rest")
    func stopDoesNotWaitForASeek() {
        let output = AudioOutput()
        let (entered, release) = holdingWrites(output)
        let seeked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
            seeked.signal()
        }
        #expect(entered.wait(timeout: .now() + 60) == .success)
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.stop()
            stopped.signal()
        }
        // Before: the stop waited on `lock` until the seek's write came back, here 60 s.
        #expect(stopped.wait(timeout: .now() + 10) == .success)
        release.signal()
        #expect(seeked.wait(timeout: .now() + 60) == .success)
        #expect(output.rate == 0)
    }

    @Test("a pause asked while a seek's clock write waits comes after it: the clock ends paused")
    func pauseKeepsItsOrder() {
        let output = AudioOutput()
        let (entered, release) = holdingWrites(output)
        let seeked = DispatchSemaphore(value: 0), paused = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
            seeked.signal()
        }
        #expect(entered.wait(timeout: .now() + 60) == .success)
        Thread.detachNewThread {
            output.pause()
            paused.signal()
        }
        // The pause waits behind the seek's write, as it waited on `lock` before.
        #expect(paused.wait(timeout: .now() + 0.3) == .timedOut)
        release.signal()
        #expect(seeked.wait(timeout: .now() + 60) == .success)
        #expect(paused.wait(timeout: .now() + 60) == .success)
        #expect(output.rate == 0)
    }

    @Test("a write asked before a stop and still waiting for its turn is dropped: the clock stays at rest")
    func aWriteAskedBeforeAStopIsDropped() {
        let output = AudioOutput()
        let (entered, release) = holdingWrites(output)
        let seeked = DispatchSemaphore(value: 0), rated = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 0)
            seeked.signal()
        }
        #expect(entered.wait(timeout: .now() + 60) == .success)
        Thread.detachNewThread {
            output.setRate(1)
            rated.signal()
        }
        // Waiting behind the seek's write, asked before the stop.
        #expect(rated.wait(timeout: .now() + 0.3) == .timedOut)
        output.stop()
        release.signal()
        #expect(seeked.wait(timeout: .now() + 60) == .success)
        #expect(rated.wait(timeout: .now() + 60) == .success)
        #expect(output.rate == 0)
    }

    @Test("a seek waiting on the preroll gate when a stop comes sets up no preroll: nothing starts the clock later")
    func aStopCancelsAPrerollStillBeingAskedFor() throws {
        let output = AudioOutput()
        let asked = DispatchSemaphore(value: 0), answer = DispatchSemaphore(value: 0)
        let first = FirstTake()
        output.videoPrerollSatisfied = { _ in
            if first.take() {
                asked.signal()
                _ = answer.wait(timeout: .now() + 60)
            }
            return false   // not ready: the seek would set up a preroll that starts the clock at its timeout
        }
        let seeked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
            seeked.signal()
        }
        #expect(asked.wait(timeout: .now() + 60) == .success)
        output.stop()
        answer.signal()
        #expect(seeked.wait(timeout: .now() + 60) == .success)
        // Past the preroll's timeout, when a preroll set up after the stop would have started the clock.
        Thread.sleep(forTimeInterval: AudioOutput.prerollTimeout + 0.5)
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
