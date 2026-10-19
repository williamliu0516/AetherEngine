import Foundation
import Testing
@testable import AetherEngine

/// A killed or crashed app leaves its `aether-segments/` folder (100-300 MB) behind. The sweep ran
/// only when the next play made a cache, and only for folders over an hour old, so the space stayed
/// taken until then. A free marker now proves the owner gone at any age, and the host sweeps at launch.
@Suite("Launch-time stale-session sweep")
struct LaunchSessionSweepTests {

    private func makeBase() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("launch-sweep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A session folder whose owner took the marker and then died: the kernel dropped the lock.
    private func killedSession(in base: URL) -> URL {
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("seg-0-0.m4s").path,
                                       contents: Data(repeating: 0xAA, count: 4096))
        let fd = SessionDirectoryLiveness.acquire(sessionDir: dir, logPrefix: "[test]")
        #expect(fd >= 0)
        close(fd)
        return dir
    }

    @Test("A killed session's folder goes at once, while a young unmarked one waits out the hour")
    func freeMarkerGoesAtAnyAge() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let killed = killedSession(in: base)
        let unmarked = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)

        SegmentCache.sweepStaleSessionDirs(baseDir: base)

        #expect(!FileManager.default.fileExists(atPath: killed.path),
                "a free marker means the owner is gone; its age proves nothing more")
        #expect(FileManager.default.fileExists(atPath: unmarked.path),
                "with no marker (a DVR ring before it locks) only age can decide")
    }

    @Test("A held folder stays, young or an hour old")
    func heldMarkerStaysAtAnyAge() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let young = SegmentCache(baseDirectory: base)
        defer { young.close() }
        let old = SegmentCache(baseDirectory: base)
        defer { old.close() }
        old.store(index: 0, data: Data(repeating: 0xBB, count: 128))
        let past = Date().addingTimeInterval(-7200)
        try? FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: old.sessionDir.path)

        SegmentCache.sweepStaleSessionDirs(baseDir: base)

        #expect(FileManager.default.fileExists(atPath: young.sessionDir.path))
        #expect(FileManager.default.fileExists(atPath: old.sessionDir.path))
        #expect(old.peekURL(index: 0) != nil)
    }

    @Test("The host's launch call sweeps the engine's own folder")
    func launchCallSweepsTheDefaultFolder() {
        let killed = killedSession(in: SegmentCache.defaultBaseDirectory)
        defer { try? FileManager.default.removeItem(at: killed) }
        let live = SegmentCache()
        defer { live.close() }

        AetherEngine.sweepStaleSessionDirectories()

        #expect(!FileManager.default.fileExists(atPath: killed.path))
        #expect(FileManager.default.fileExists(atPath: live.sessionDir.path))
    }
}
