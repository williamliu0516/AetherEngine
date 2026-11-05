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
}
