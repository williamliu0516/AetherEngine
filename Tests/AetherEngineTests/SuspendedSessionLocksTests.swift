import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// An app suspended while it holds a file lock is killed (RunningBoard's 0xdead10cc): Zool's iPad app on a Mac, a
/// player open while its window was away (TestFlight 3203 and 5162, every thread idle), with the sessions'
/// `session.lock` held. A host lets them go as it leaves the foreground (`AetherEngine.releaseSessionLocks`) and takes
/// them back as it returns; meanwhile this process's own sweeps keep the sessions' folders.
@Suite("Session locks let go while the host is away", .serialized)
struct SuspendedSessionLocksTests {

    private func makeBase() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("suspended-locks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Whether another open file description can take the marker: nobody holds its lock.
    private func canLock(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    @discardableResult
    private func backdate(_ url: URL, seconds: TimeInterval = 7200) -> Bool {
        let past = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: url.path)
        let read = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return read.map { $0 < Date().addingTimeInterval(-3600) } ?? false
    }

    @Test("A segment cache lets go of its lock while away, keeps its folder, and takes it back")
    func aCacheLetsGoAndTakesBack() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let live = SegmentCache(baseDirectory: base)
        defer { live.close() }
        let marker = live.sessionDir.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        let heldBefore = !canLock(marker)
        #expect(heldBefore)

        AetherEngine.releaseSessionLocks()
        let letGo = canLock(marker)
        #expect(letGo, "the lock that gets a suspended app killed is let go")
        let state = SessionDirectoryLiveness.state(live.sessionDir)
        #expect(state == .held, "this process still reads its own session as live")
        #expect(backdate(live.sessionDir), "the fixture must actually be older than the cutoff")
        // A session that starts while away sweeps, and lets go of its own lock at once.
        let second = SegmentCache(baseDirectory: base)
        defer { second.close() }
        let kept = FileManager.default.fileExists(atPath: live.sessionDir.path)
        #expect(kept, "a sibling's sweep keeps the let-go session's folder")
        let secondMarker = second.sessionDir.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        let secondLetGo = canLock(secondMarker)
        #expect(secondLetGo)

        AetherEngine.retakeSessionLocks()
        let heldAgain = !canLock(marker)
        #expect(heldAgain)
        let secondHeld = !canLock(secondMarker)
        #expect(secondHeld)
    }

    @Test("The software FIFO lets go of its lease while away, and its own sweep keeps it")
    func theFIFOLetsGoAndItsSweepKeepsIt() throws {
        let parent = makeBase()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64, parentDirectory: parent)
        defer { try? fifo.close() }
        let marker = fifo.storageDirectory.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        let heldBefore = !canLock(marker)
        #expect(heldBefore)

        AetherEngine.releaseSessionLocks()
        let letGo = canLock(marker)
        #expect(letGo)
        // Three days on: past the FIFO sweep's one-day age, where only the lease keeps a folder.
        let swept = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: parent,
                                                                 now: Date().addingTimeInterval(3 * 86_400))
        #expect(swept.removedCount == 0)
        let kept = FileManager.default.fileExists(atPath: fifo.storageDirectory.path)
        #expect(kept)

        AetherEngine.retakeSessionLocks()
        let heldAgain = !canLock(marker)
        #expect(heldAgain)
    }

    @Test("A closed cache's marker leaves the registry: a later sweep reads it as its owner's going")
    func aClosedMarkerLeavesTheRegistry() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(baseDirectory: base)
        let probe = open(cache.sessionDir.appendingPathComponent(SessionDirectoryLiveness.markerName).path,
                         O_RDONLY | O_CLOEXEC)
        defer { if probe >= 0 { Darwin.close(probe) } }
        let registered = SessionDirectoryLiveness.isRegistered(probe)
        #expect(registered)
        cache.close()
        let stillRegistered = SessionDirectoryLiveness.isRegistered(probe)
        #expect(!stillRegistered)
    }

    /// Codex's review, 1: a let go asked while an acquisition holds its new lock but has not registered it waits for
    /// the registration, then lets go of it too: the lock is not kept through the suspension.
    @Test("A let go racing an acquisition lets go of the new lock too")
    func aLetGoRacingAnAcquisition() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let letGoDone = DispatchSemaphore(value: 0)
        SessionDirectoryLiveness.holdHookForTesting = {
            SessionDirectoryLiveness.holdHookForTesting = nil
            Thread.detachNewThread {
                AetherEngine.releaseSessionLocks()
                letGoDone.signal()
            }
            // The let go is asked now, between this acquisition's flock and its registration.
            Thread.sleep(forTimeInterval: 0.05)
        }
        let cache = SegmentCache(baseDirectory: base)
        defer { cache.close() }
        let waited = letGoDone.wait(timeout: .now() + 5)
        #expect(waited == .success)
        let marker = cache.sessionDir.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        let letGo = canLock(marker)
        #expect(letGo, "the acquisition's lock went with the let go")
        AetherEngine.retakeSessionLocks()
        let heldAgain = !canLock(marker)
        #expect(heldAgain)
    }

    /// Codex's review, 2: a sweep that read a marker as no one's in the registry, its owner registering and letting go
    /// of it that moment, never then takes the lock for a dead owner's: the registry's word and the probe are one step.
    @Test("A sweep's probe racing a registration reads the session as live")
    func aProbeRacingARegistration() throws {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let markerPath = dir.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        // An owner that has locked its marker and not yet registered it, while the host is away.
        let owner = open(markerPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(owner >= 0)
        #expect(flock(owner, LOCK_EX | LOCK_NB) == 0)
        AetherEngine.releaseSessionLocks()
        defer {
            SessionDirectoryLiveness.release(owner)
            AetherEngine.retakeSessionLocks()
        }
        let registeredNow = DispatchSemaphore(value: 0)
        SessionDirectoryLiveness.probeHookForTesting = {
            SessionDirectoryLiveness.probeHookForTesting = nil
            Thread.detachNewThread {
                // Registered while away: its lock let go at once.
                SessionDirectoryLiveness.adopt(owner)
                registeredNow.signal()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let state = SessionDirectoryLiveness.state(dir)
        #expect(state == .held, "the owner registered and let go mid-probe; its session is live")
        let waited = registeredNow.wait(timeout: .now() + 5)
        #expect(waited == .success)
        let after = SessionDirectoryLiveness.state(dir)
        #expect(after == .held)
    }

    /// Codex's review, 4: a take back that another descriptor's lock refuses is counted for the host's diagnostics and
    /// tried again at the next session's acquisition.
    @Test("A refused take back is counted and retried at the next acquisition")
    func aRefusedTakeBackIsRetried() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(baseDirectory: base)
        defer { cache.close() }
        let marker = cache.sessionDir.appendingPathComponent(SessionDirectoryLiveness.markerName).path
        AetherEngine.releaseSessionLocks()
        // Another process's sweep probing it at the moment of the return.
        let probe = open(marker, O_RDONLY | O_CLOEXEC)
        #expect(flock(probe, LOCK_EX | LOCK_NB) == 0)
        AetherEngine.retakeSessionLocks()
        let counted = AetherEngine.sessionLocksNotRetaken
        #expect(counted >= 1)
        flock(probe, LOCK_UN)
        Darwin.close(probe)
        let next = SegmentCache(baseDirectory: base)
        defer { next.close() }
        let held = !canLock(marker)
        #expect(held, "the next acquisition took it back")
        let left = AetherEngine.sessionLocksNotRetaken
        #expect(left == 0)
    }
}

