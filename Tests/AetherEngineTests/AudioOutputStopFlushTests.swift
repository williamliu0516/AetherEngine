import Foundation
import CoreMedia
import Testing
@testable import AetherEngine

/// A stop's renderer flush resets the audio queue with a synchronous call on its server's queue, and the clock's rest
/// waits on the queue's lock. With the output on a device that never starts (the iOS simulator on the host's virtual
/// device; the Studio itself, whose default output is that device), the server sat in the start for good, and the
/// recovery's stop on the main thread waited behind it holding `lock`, the feed thread behind that: the player and the
/// whole app froze (b18, 2026-11-03). Both run on `stopQueue` now, outside `lock`. A step that has to happen gets 60 s
/// (a semaphore wait does not hear `.timeLimit`); only the claims (10 s) are tight.
@Suite("AudioOutput stop off the caller's thread", .offCooperativePool, .timeLimit(.minutes(2)))
struct AudioOutputStopFlushTests {

    @Test("a stop returns while its flush and the clock's rest are held, the lock free for the feed; the clock ends at rest")
    func stopDoesNotWaitForTheAudioQueue() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 30, preferredTimescale: 600), rate: 1)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        output.whileStoppingForTesting = {
            entered.signal()
            _ = release.wait(timeout: .now() + 60)
        }
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            output.stop()
            stopped.signal()
        }
        // Before: the stop flushed in place, under `lock`, here for 60 s.
        #expect(stopped.wait(timeout: .now() + 10) == .success)
        #expect(entered.wait(timeout: .now() + 60) == .success)
        let read = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = output.epoch   // takes `lock`, as the feed's enqueue and clock writes do
            read.signal()
        }
        #expect(read.wait(timeout: .now() + 10) == .success)
        release.signal()
        AudioOutput.stopQueue.sync {}
        #expect(output.rate == 0)
    }
}
