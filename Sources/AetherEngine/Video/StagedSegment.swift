import Foundation

/// Where one segment's bytes live while the muxer writes it and after the cache adopts it: a file in
/// the session directory, or a `SegmentMemoryBuffer` (W3167).
enum StagedSegment: @unchecked Sendable {
    case file(URL)
    case memory(SegmentMemoryBuffer)

    /// Identifies these bytes without holding them: a file by its path (unique per segment and
    /// epoch), a buffer by its id.
    enum Key: Hashable, Sendable {
        case file(URL)
        case memory(UInt64)
    }

    var key: Key {
        switch self {
        case .file(let url): return .file(url)
        case .memory(let buffer): return .memory(buffer.id)
        }
    }

    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    /// The whole segment: a mapped file or a pinned buffer. nil when the bytes are gone.
    func read() -> Data? {
        switch self {
        case .file(let url):
            return try? Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        case .memory(let buffer):
            return buffer.pinnedData()
        }
    }

    /// Removes a file; a buffer is freed once nothing references it.
    func discard() {
        if case .file(let url) = self { try? FileManager.default.removeItem(at: url) }
    }
}
