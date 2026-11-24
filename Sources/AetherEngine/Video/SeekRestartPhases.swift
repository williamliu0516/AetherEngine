import Foundation

/// W3147: one producer restart a seek caused, split into its steps, in seconds, so a host's report can say where a
/// slow seek's time went (G2UU: 4K DV seeks from a cloud drive showed their picture after 4-15 s and the report could
/// not say why). The steps follow one another: `stop`, then `reopen` (only when the old demuxer was replaced), then
/// `seek`, then `keyframe`, then `served`; what is left of the host's own "picture after" is AVPlayer's.
public struct SeekRestartPhases: Sendable, Equatable {
    /// `ProcessInfo.systemUptime` when the restart began: a host keeps the ones that began after its seek did.
    public var began: TimeInterval
    /// The plan segment the new producer starts at.
    public var segment: Int
    /// Waiting for the old producer's pump to stop.
    public var stop: Double
    /// Opening a fresh demuxer in place of a wedged or failed one; nil when the old one was kept.
    public var reopen: Double?
    /// The fresh open failed and the old demuxer was kept.
    public var reopenFailed: Bool
    /// The demuxer seek to the segment's start.
    public var seek: Double
    /// From the seek's end to the first video keyframe the new producer took; nil until it takes one.
    public var keyframe: Double?
    /// From that keyframe to the first segment at or after `segment` handed to the player; nil until then.
    public var served: Double?

    public init(began: TimeInterval, segment: Int, stop: Double = 0, reopen: Double? = nil, reopenFailed: Bool = false,
                seek: Double = 0, keyframe: Double? = nil, served: Double? = nil) {
        self.began = began
        self.segment = segment
        self.stop = stop
        self.reopen = reopen
        self.reopenFailed = reopenFailed
        self.seek = seek
        self.keyframe = keyframe
        self.served = served
    }
}

/// The session's last few restarts' steps (`SeekRestartPhases`). Written from the restart, pump and server threads.
final class SeekRestartPhaseLog: @unchecked Sendable {
    static let kept = 4

    private struct Entry {
        let id: UInt64
        var phases: SeekRestartPhases
        /// When the last noted step ended; the next step is measured from it.
        var mark: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0

    /// A restart at `segment` begins; returns its handle for the later steps.
    func begin(segment: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        entries.append(Entry(id: nextID, phases: SeekRestartPhases(began: now, segment: segment), mark: now))
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
        return nextID
    }

    /// The restart's own steps, up to and including the demuxer seek, which ended at `now`.
    func noteSteps(_ id: UInt64, stop: Double, reopen: Double?, reopenFailed: Bool, seek: Double,
                   now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        update(id) { entry in
            entry.phases.stop = stop
            entry.phases.reopen = reopen
            entry.phases.reopenFailed = reopenFailed
            entry.phases.seek = seek
            entry.mark = now
        }
    }

    /// The restart's producer took its first video keyframe.
    func noteKeyframe(_ id: UInt64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        update(id) { entry in
            guard entry.phases.keyframe == nil else { return }
            entry.phases.keyframe = max(0, now - entry.mark)
            entry.mark = now
        }
    }

    /// Segment `index` was handed to the player: the newest restart whose producer has its keyframe and covers
    /// `index` takes it as its first served segment. A segment below the restart's start is the place the seek left.
    func noteServed(index: Int, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        guard let i = entries.indices.last, entries[i].phases.keyframe != nil, entries[i].phases.served == nil,
              index >= entries[i].phases.segment else { return }
        entries[i].phases.served = max(0, now - entries[i].mark)
        entries[i].mark = now
    }

    var snapshot: [SeekRestartPhases] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.phases)
    }

    private func update(_ id: UInt64, _ change: (inout Entry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }
}
