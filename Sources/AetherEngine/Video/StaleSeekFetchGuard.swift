import Foundation

/// A request for the place a seek left, arriving after the seek's own run has begun, is AVPlayer's from before the
/// seek: it reached the loopback server late, and serving it the usual way re-anchored the producer back there, after
/// which the seek's next request re-anchored it again (a 4K Dolby Vision film from a cloud drive over a ~51 Mbit/s
/// link: a stale seg70 GET after the seek, the picture after 14.8 s instead of ~3 s; W3146, 2026-11-24).
///
/// Such a request is answered from the cache when the segment is resident, else refused with the retriable answer,
/// and never moves the producer. The window opens only once the seek's own segment (or the one before it, where
/// AVPlayer lands on a boundary) has been asked for, so a seek AVPlayer serves from its own buffer, which asks for
/// nothing at the target, never opens it, and it closes after `openSeconds`. A request refused once and asked again
/// is wanted after all (AVPlayer has gone back there): it is served the usual way and closes the window. A later seek
/// opens a window of its own.
///
/// Not thread-safe; `VideoSegmentProvider` holds it under its `stateLock`.
struct StaleSeekFetchGuard {
    /// How long after the seek's own run begins a request outside it counts as stale.
    static let openSeconds: Double = 10
    /// Segments past the newest one the seek's run has asked for that still belong to that run (AVPlayer asks a few
    /// ahead of what it plays).
    static let runSlack = 8

    private var seekIndex: Int?
    private var noted: Double = 0
    private var openedAt: Double?
    private var runFront = 0
    private var refused: Set<Int> = []

    /// A seek asked for segment `index` at `now` (uptime seconds).
    mutating func noteSeek(index: Int, now: Double) {
        seekIndex = index
        noted = now
        openedAt = nil
        runFront = index
        refused = []
    }

    /// Whether a request for `index` at `now` is one the seek left behind.
    func isStale(_ index: Int, now: Double) -> Bool {
        guard let seekIndex, let openedAt, now - openedAt <= Self.openSeconds else { return false }
        if refused.contains(index) { return false }
        return index < seekIndex - 1 || index > runFront + Self.runSlack
    }

    /// A request for `index` that is served the usual way: the seek's own one opens the window, and the run's later
    /// ones move its front.
    mutating func noteWanted(_ index: Int, now: Double) {
        guard let seekIndex else { return }
        if refused.contains(index) {
            self.seekIndex = nil
            return
        }
        if openedAt == nil {
            // A seek whose run never began within the window (served from AVPlayer's own buffer) opens nothing later.
            guard now - noted <= Self.openSeconds, index == seekIndex || index == seekIndex - 1 else { return }
            openedAt = now
        }
        if index >= seekIndex - 1 { runFront = max(runFront, index) }
    }

    /// A stale request for `index` was refused; asked again, it is served the usual way.
    mutating func noteRefused(_ index: Int) {
        refused.insert(index)
    }
}
