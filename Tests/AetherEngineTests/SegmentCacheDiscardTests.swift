import Foundation
import Testing
@testable import AetherEngine

/// Zool's fork: a closed session's folder is removed on `SegmentCache.discardQueue`, at background QoS, so the unlink of
/// every segment it kept yields to the host's own writes (an audio switch on an iPhone SE: 48 segments unlinked while
/// the main thread waited 1.74 s on a one-line diagnostics write).
struct SegmentCacheDiscardTests {

    @Test("a closed cache's folder is removed on the background queue, its segments with it")
    func folderGoesOnTheBackgroundQueue() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("discard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let cache = SegmentCache(baseDirectory: base)
        for index in 0..<4 { cache.store(index: index, data: Data(repeating: 0xAB, count: 4096)) }
        let dir = cache.sessionDir
        let stored = FileManager.default.fileExists(atPath: dir.path)
        cache.close()
        SegmentCache.discardQueue.sync {}
        let gone = !FileManager.default.fileExists(atPath: dir.path)
        let qos = SegmentCache.discardQueue.qos
        #expect(stored)
        #expect(gone)
        #expect(qos == .background)
    }
}
