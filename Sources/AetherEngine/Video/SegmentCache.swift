import Darwin
import Foundation

/// Sliding-window cache for HLS-fMP4 segments. Bytes go to
/// <NSTemporaryDirectory>/aether-segments/<uuid>/seg-N-G.m4s, or, for a VOD session with a memory
/// budget, into memory (W3167: `SegmentMemoryBuffer`, see "Memory segments" below).
/// File reads use .alwaysMapped (kernel pages in/out under memory pressure). Window:
/// [currentTargetIndex - backwardWindow, currentTargetIndex + forwardWindow].
/// The producer pauses via awaitFetchHighWater once forwardWindow ahead of target.
// Thread-safe: all mutable state is guarded by `condition` (NSCondition), so it is safe to share
// across the producer/provider threads and capture in @Sendable closures.
final class SegmentCache: @unchecked Sendable {

    /// AE#412: where a stored segment's first random-access point sits, as an offset from the
    /// segment's ADVERTISED start (its plan boundary). An offset, not an absolute time, so it is
    /// independent of the item / source / display axes and survives an epoch that opened early.
    ///
    /// `<= 0` means the segment opens on a sync sample and serves any position inside it. A positive
    /// offset means the first sync sample sits that far in, so only positions at or after it can
    /// start a decode run. `.none` means the segment carries no sync sample at all: audio cut it on
    /// a plan boundary the keyframe-gated cutter had folded, so nothing in it can start one.
    enum VideoReach: Equatable, Sendable {
        case syncAt(offsetSeconds: Double)
        case none

        /// Whether a cold arrival aiming `offsetSeconds` into this segment can be served from it.
        func serves(offsetSeconds: Double) -> Bool {
            guard case .syncAt(let syncOffset) = self else { return false }
            return syncOffset <= offsetSeconds
        }
    }

    private let condition = NSCondition()
    private let onResidentSetChanged: (@Sendable () -> Void)?

    private let forwardWindow: Int
    /// 20 covers Continuous-Audio handover refetches (~7-10 segments backward); smaller values
    /// cascaded into restart chains that reset the FLAC bridge PTS and caused audible glitches.
    private let backwardWindow: Int
    /// Byte budget for retaining segments OUTSIDE the hard window (#93 / Sodalite#32). While the
    /// cache's total footprint fits the budget, already-produced segments beyond the window stay
    /// resident (evicted farthest-from-target first once it fills), so a backward seek into watched
    /// content is a cache hit and never fires the producer restart that wedges slow sources (#93)
    /// and detaches AVKit's PiP legible renderer (Sodalite#32). 0 = window-only legacy pruning
    /// (live sessions, where the sliding playlist already dropped everything behind the window).
    private let retentionBudgetBytes: Int
    private let nativeLiveDVRPolicy: LiveDVRRetentionPolicy?
    private var nativeLiveRetentionFloor = 0
    private lazy var nativeLiveExpiryQueue = DispatchQueue(label: "com.aetherengine.live-expiry", qos: .utility)
    private var nativeLiveExpiryTimer: DispatchSourceTimer? // condition; opt-in, cancelled by close

    private var entries: [Int: StagedSegment] = [:]
    /// Per-index byte ledger for _totalBytes. Stat-on-eviction was wrong when same index was
    /// overwritten (stat returned new size, old bytes stayed counted forever).
    private var entryBytes: [Int: Int] = [:]

    /// Progressive delivery: the segments a producer is writing right now, index to staging file.
    /// Registered when the producer opens the segment (`beginInProgress`), removed when it is
    /// adopted or abandoned. A serve that finds its index here reads the staging file as it grows
    /// (`ProgressiveSegmentReader`) instead of waiting for the cut.
    private var inProgress: [Int: StagedSegment] = [:]
    /// The staging file (or memory buffer) each recently adopted segment came from, and its final
    /// size, so a progressive reader can tell that the bytes IT holds were sealed, rather than the
    /// same index produced again by a later epoch. Keyed by staging file or buffer id (unique per
    /// segment and epoch; an id, so remembering a buffer never keeps its bytes) and bounded to the
    /// most recent adoptions in adoption order: evicting by index dropped every adoption below the
    /// 64 highest at once, so after a backward seek each reader read as abandoned.
    private var sealedFromStaging: [StagedSegment.Key: Int] = [:]
    private var sealedStagingOrder: [StagedSegment.Key] = []

    // MARK: Memory segments (W3167)
    //
    // A VOD cache with a `memoryBudget` hands the producer a `SegmentMemoryBuffer` for each segment
    // while the counted memory plus the next segment fits B (`SegmentMemoryBudget`); past B a segment
    // is written to a staging file as before. Live never gets one (review H1: a purged segment behind
    // a live edge has no producer to re-make it).
    //
    // Counted memory is the lead: memory segments from `memoryKeepBehind` below the target up to the
    // producer's head, plus the one being written. Everything else (behind the lead, an island a seek
    // left above it) is volatile: the kernel may empty it, a read reclaims it or finds it emptied
    // (dropped, the producer makes it again), and it is capped at B. When B shrinks (the process's
    // available memory fell, a memory-pressure event), the band behind the target goes volatile
    // first, then the farthest-ahead segments are spilled to files off the lock.

    private let memoryBudget: SegmentMemoryBudget?
    /// Segments kept counted below the target: the Continuous-Audio handover refetch reaches ~7-10
    /// back (review M3), and a purge there is a restart that re-arms the FLAC bridge.
    static let memoryKeepBehind = 10
    private var lastPressureAt: Double?
    private var lastAdoptedBytes = 0
    private var spillScheduled = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let spillQueue = DispatchQueue(label: "com.aetherengine.segmentcache.spill", qos: .utility)
    /// Bytes this cache wrote to files: staging writes the muxer reports, `store`, and spills.
    private var _bytesWrittenToDisk = 0
    /// Memory segments spilled to files, and volatile ones found emptied. Diagnostics and tests.
    private var _spilledSegments = 0
    private var _purgedSegments = 0

    /// Pinned in RAM (~3.5 KB); AVPlayer fetches exactly once per session; never evicted.
    private var initSegment: Data?

    /// Mid-session SSAI program-switch inits: (versionID, fromSegment, data). Version 0 = session init.
    private var initVersions: [(versionID: Int, fromSegment: Int, data: Data)] = []

    private var closed = false
    /// Declared by provider at top of each mediaSegment(at:); non-monotonic (backward scrub is valid).
    private var currentTargetIndex: Int = -1

    /// Lowest index of the consumer's current uninterrupted fetch sequence, and the highest index it has
    /// reached in it. A seek flushes the consumer's buffer, so only within one sequence does everything
    /// between the playhead and the target sit in that buffer, which is what
    /// `contiguousForwardFrontier(fromPlayhead:)` rests on.
    private var fetchFloor: Int = -1
    private var fetchFront: Int = -1

    let sessionDir: URL

    /// AE#451: the `SessionDirectoryLiveness` marker held for as long as this cache lives. -1 means
    /// unheld (open or flock failed); such a session is swept by age like before AE#451.
    private var lockFD: Int32 = -1

    private var _totalBytes: Int = 0

    /// Monotonic across prunes; NOT decremented by pruneOutsideWindow. Lets VideoSegmentProvider
    /// detect gaps below the producer's write head after eviction erases them from indexRange().
    private var _highestStoredIndex: Int = -1

    /// Audit SEG-4: every stored generation of an index gets its own file name, so a URL names exactly
    /// one set of bytes. A reader dropping a vanished entry, or a prune deleting a doomed one after
    /// unlocking, can then never hit a newer adoption of the same index.
    private var fileGeneration: UInt64 = 0

    private func nextSegmentFileURL(index: Int) -> URL {
        condition.lock()
        fileGeneration += 1
        let generation = fileGeneration
        condition.unlock()
        return sessionDir.appendingPathComponent("seg-\(index)-\(generation).m4s")
    }
    /// Plan index -> how many pumps passed it without opening a segment (#358). Survives producer
    /// restarts on purpose: the repeat across a restart is the signal.
    private var foldCounts: [Int: Int] = [:]
    /// AE#412: what a stored segment's video is worth to a COLD arrival, per index. Absent = the
    /// producer did not record it (live, or an unresolved time base), and callers must treat that
    /// as "no claim" rather than as bad news.
    private var videoReaches: [Int: VideoReach] = [:]
    /// #369: log-classification threshold: a run wider than this is a discontinuity-scale cut
    /// leap, not a long GOP. (It used to DROP such runs from the counters on the assumption they
    /// were repositions; the field case was a 2^33 wrap folding 312 indices, and dropping it left
    /// every fold counter at 0, which is exactly what disarms the #358 recovery arms.)
    static let maxFoldRunLength = 64

    /// The volume holding `sessionDir` ran out of space while this session wrote to it: the
    /// directory, a segment, or a muxer's staging file. Read when the pump gives up, so the failure
    /// names the full disk instead of the audio or the source, neither of which is at fault.
    /// Guarded by `condition`.
    private var storageExhaustedLatch = false

    var storageExhausted: Bool {
        condition.lock(); defer { condition.unlock() }
        return storageExhaustedLatch
    }

    func noteStorageExhausted() {
        condition.lock()
        let first = !storageExhaustedLatch
        storageExhaustedLatch = true
        condition.unlock()
        if first {
            EngineLog.emit("[SegmentCache] the segment volume is out of space at \(sessionDir.path)",
                           category: .session)
        }
    }

    /// A write that failed because the volume is full: `NSFileWriteOutOfSpaceError` from Foundation,
    /// `ENOSPC` from POSIX, or either one underneath a wrapping error.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// (10, 20)=30 entries, ~300 MB at 4K HDR HEVC ~10 MB/seg.
    init(forwardWindow: Int = 10, backwardWindow: Int = 20, retentionBudgetBytes: Int = 0,
         baseDirectory: URL? = nil, nativeLiveDVRPolicy: LiveDVRRetentionPolicy? = nil,
         memoryBudget: SegmentMemoryBudget? = nil, onResidentSetChanged: (@Sendable () -> Void)? = nil) {
        self.forwardWindow = forwardWindow
        self.backwardWindow = backwardWindow
        self.retentionBudgetBytes = retentionBudgetBytes
        self.nativeLiveDVRPolicy = nativeLiveDVRPolicy
        // H1: a live session's segments always go to files, whatever the caller passed.
        self.memoryBudget = nativeLiveDVRPolicy == nil ? memoryBudget : nil
        self.onResidentSetChanged = onResidentSetChanged

        // aether-segments/ prefix lets sweepStaleSessionDirs() find sibling dirs from crashed sessions.
        let baseDir = baseDirectory ?? Self.defaultBaseDirectory
        let sessionID = UUID().uuidString
        self.sessionDir = baseDir.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            EngineLog.emit("[SegmentCache] session dir create failed at \(sessionDir.path): \(error)",
                           category: .session)
            if Self.isOutOfSpace(error) { storageExhaustedLatch = true }
        }

        // Before the sweep, so a sibling constructed in the same breath cannot read this session
        // as unheld. Until the marker is in place the directory reads as unmarked, and an unmarked
        // directory this young is never a sweep candidate.
        self.lockFD = Self.acquireLiveMarker(sessionDir: sessionDir)

        Self.sweepStaleSessionDirs(baseDir: baseDir, currentSession: sessionID)

        if self.memoryBudget != nil {
            // System pressure, not this process's own limit (review H3): the limit is tracked by
            // re-reading the budget at each segment open and target change; this only adds the
            // earlier warning where the system gives one.
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: spillQueue)
            source.setEventHandler { [weak self] in self?.noteMemoryPressure() }
            source.resume()
            memoryPressureSource = source
        }
    }

    deinit {
        memoryPressureSource?.cancel()
        nativeLiveExpiryTimer?.cancel()
        releaseLiveMarker()
    }

    private static func acquireLiveMarker(sessionDir: URL) -> Int32 {
        SessionDirectoryLiveness.acquire(sessionDir: sessionDir, logPrefix: "[SegmentCache]")
    }

    private func releaseLiveMarker() {
        condition.lock()
        let fd = lockFD
        lockFD = -1
        condition.unlock()
        SessionDirectoryLiveness.release(fd)
    }

    static let defaultBaseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("aether-segments", isDirectory: true)

    /// A held marker keeps its directory at any age; a free one (owner killed or crashed) goes at any
    /// age; an unmarked directory goes after an hour, as before markers. Run by every new cache and,
    /// through `AetherEngine.sweepStaleSessionDirectories()`, once at the host's launch.
    static func sweepStaleSessionDirs(baseDir: URL = defaultBaseDirectory, currentSession: String? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent != currentSession {
            switch SessionDirectoryLiveness.state(entry) {
            case .held:
                // AE#451: age says how long it has been there, not whether anyone is still using it.
                continue
            case .free:
                break
            case .unmarked:
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                guard created == nil || created! < cutoff else { continue }
            }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Writer side

    func setInit(_ data: Data) {
        condition.lock()
        initSegment = data
        condition.broadcast()
        condition.unlock()
    }

    /// Register fresh init at SSAI program switch valid from `fromSegment`. Idempotent on fromSegment.
    func addInitVersion(_ data: Data, fromSegment: Int) {
        condition.lock()
        defer { condition.unlock() }
        if let i = initVersions.firstIndex(where: { $0.fromSegment == fromSegment }) {
            initVersions[i].data = data
        } else {
            let nextID = (initVersions.map { $0.versionID }.max() ?? 0) + 1
            initVersions.append((versionID: nextID, fromSegment: fromSegment, data: data))
            initVersions.sort { $0.fromSegment < $1.fromSegment }
        }
        condition.broadcast()
    }

    func initVersionID(forSegment index: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        var id = 0
        for v in initVersions where v.fromSegment <= index { id = v.versionID }
        return id
    }

    func initData(versionID: Int) -> Data? {
        condition.lock(); defer { condition.unlock() }
        if versionID == 0 { return initSegment }
        return initVersions.first(where: { $0.versionID == versionID })?.data
    }

    /// AE#451: a write into a directory that is no longer there is not a dead session. Whatever
    /// removed it (a sibling's sweep on an older build, the OS reclaiming tmp) is outside this
    /// class, and without this a single deletion leaves the session permanently unable to store,
    /// so it never recovers by re-producing. Re-takes the live marker too: the old one went with
    /// the directory, and an unmarked directory is the next sweeper's candidate.
    private func restoreSessionDirIfMissing() -> Bool {
        condition.lock()
        let isClosed = closed
        condition.unlock()
        // A store racing close() must not resurrect the directory close() just deleted, and must
        // not leave a held marker behind that keeps the next sweep away from it.
        guard !isClosed else { return false }
        guard !FileManager.default.fileExists(atPath: sessionDir.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            EngineLog.emit("[SegmentCache] session dir restore failed at \(sessionDir.path): \(error)",
                           category: .session)
            if Self.isOutOfSpace(error) { noteStorageExhausted() }
            return false
        }
        releaseLiveMarker()
        let fd = Self.acquireLiveMarker(sessionDir: sessionDir)
        condition.lock()
        lockFD = fd
        condition.unlock()
        EngineLog.emit("[SegmentCache] session dir was deleted underneath a live session; restored (AE#451)",
                       category: .session)
        return true
    }

    func store(index: Int, data: Data) {
        let fileURL = nextSegmentFileURL(index: index)
        var writeOK: Bool
        do {
            try data.write(to: fileURL, options: [.atomic])
            writeOK = true
        } catch {
            // The retry's own error decides: a missing directory restored onto a full volume fails
            // the second write with ENOSPC, behind a first error that only said the file was missing.
            var finalError: Error? = error
            if restoreSessionDirIfMissing() {
                do {
                    try data.write(to: fileURL, options: [.atomic])
                    finalError = nil
                } catch {
                    finalError = error
                }
            }
            if let finalError {
                EngineLog.emit("[SegmentCache] write failed seg-\(index): \(finalError)",
                               category: .session)
                if Self.isOutOfSpace(finalError) { noteStorageExhausted() }
                writeOK = false
            } else {
                writeOK = true
            }
        }

        condition.lock()
        if writeOK { _bytesWrittenToDisk += data.count }
        // store racing close() must not resurrect bookkeeping; entry would point into deleted sessionDir.
        guard !closed else {
            condition.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        // A re-store of a resident index changes bytes, not residency; only an insertion or an
        // eviction moves the set, and both are already known here without walking it.
        var residentSetChanged = false
        var superseded: StagedSegment?
        if writeOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            superseded = entries.updateValue(.file(fileURL), forKey: index)
            residentSetChanged = superseded == nil
            entryBytes[index] = data.count
            _totalBytes += data.count
            if index > _highestStoredIndex { _highestStoredIndex = index }
            noteStoreLocked(index)
        }
        let doomed = pruneOutsideWindow()
        if !doomed.isEmpty { residentSetChanged = true }
        let memory = rebalanceMemoryLocked()
        condition.broadcast()
        condition.unlock()
        superseded?.discard()
        for segment in doomed { segment.discard() }
        finishRebalance(memory)
        if residentSetChanged { onResidentSetChanged?() }
    }

    /// Adopt a staging file via rename(2). Page cache pages stay warm; skips a Swift Data round trip.
    func adopt(index: Int, stagingPath: URL, byteCount: Int, videoReach: VideoReach? = nil) {
        adopt(index: index, staged: .file(stagingPath), byteCount: byteCount, videoReach: videoReach)
    }

    /// Adopt the segment the producer just sealed: a staging file is renamed to its final name, a
    /// memory buffer becomes the entry as it stands.
    ///
    /// `videoReach` (AE#412) is what this segment's video offers a cold arrival; nil leaves the
    /// previous claim in place only if the index is re-adopted without one, which no caller does.
    func adopt(index: Int, staged: StagedSegment, byteCount: Int, videoReach: VideoReach? = nil) {
        let stored: StagedSegment
        var adoptOK = true
        switch staged {
        case .memory:
            stored = staged
        case .file(let stagingPath):
            let fileURL = nextSegmentFileURL(index: index)
            stored = .file(fileURL)
            do {
                try FileManager.default.moveItem(at: stagingPath, to: fileURL)
            } catch {
                if restoreSessionDirIfMissing(),
                   (try? FileManager.default.moveItem(at: stagingPath, to: fileURL)) != nil {
                } else {
                    EngineLog.emit("[SegmentCache] adopt failed seg-\(index): \(error)",
                                   category: .session)
                    try? FileManager.default.removeItem(at: stagingPath)
                    adoptOK = false
                }
            }
        }

        let key = staged.key
        condition.lock()
        // Sealed or not, these staged bytes are no longer being written.
        if inProgress[index]?.key == key { inProgress.removeValue(forKey: index) }
        if adoptOK {
            if sealedFromStaging.updateValue(byteCount, forKey: key) == nil {
                sealedStagingOrder.append(key)
            }
            while sealedStagingOrder.count > Self.sealedStagingMemory {
                sealedFromStaging.removeValue(forKey: sealedStagingOrder.removeFirst())
            }
        }
        guard !closed else {
            condition.broadcast()
            condition.unlock()
            if adoptOK { stored.discard() }
            return
        }
        var residentSetChanged = false
        var superseded: StagedSegment?
        if adoptOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            superseded = entries.updateValue(stored, forKey: index)
            residentSetChanged = superseded == nil
            entryBytes[index] = byteCount
            _totalBytes += byteCount
            lastAdoptedBytes = byteCount
            if index > _highestStoredIndex { _highestStoredIndex = index }
            noteStoreLocked(index)
            // A later epoch produced what an earlier one passed over: a re-anchor moved the
            // boundaries and this index is no longer a hole (#358).
            foldCounts.removeValue(forKey: index)
            // AE#412: the claim describes THESE bytes, so a re-adoption replaces it, and an
            // adoption that cannot state one must not leave the old epoch's claim standing.
            videoReaches[index] = videoReach
        }
        let doomed = pruneOutsideWindow()
        if !doomed.isEmpty { residentSetChanged = true }
        let memory = rebalanceMemoryLocked()
        condition.broadcast()
        condition.unlock()
        superseded?.discard()
        for segment in doomed { segment.discard() }
        finishRebalance(memory)
        if residentSetChanged { onResidentSetChanged?() }
    }

    /// Zool's fork: where a closed session's folder is removed. An audio switch or a close unlinks every segment the
    /// session kept, and done in place, at the closing task's priority, that I/O held the file system for the host's
    /// own writes: on an iPhone SE an audio switch unlinked 48 segments (2.1 s of unlink under System Trace) while the
    /// main thread waited 1.74 s on a one-line diagnostics write. At background QoS the system throttles this I/O
    /// behind everyone else's. The live marker is released before, so a folder a killed process leaves is the launch
    /// sweep's.
    static let discardQueue = DispatchQueue(label: "com.aetherengine.segmentcache.discard", qos: .background)

    func close() {
        condition.lock()
        closed = true
        let expiryTimer = nativeLiveExpiryTimer
        nativeLiveExpiryTimer = nil
        let dir = sessionDir
        let hadEntries = !entries.isEmpty
        entries.removeAll(keepingCapacity: false)
        entryBytes.removeAll(keepingCapacity: false)
        videoReaches.removeAll(keepingCapacity: false)
        initSegment = nil
        initVersions.removeAll(keepingCapacity: false)
        inProgress.removeAll(keepingCapacity: false)
        sealedFromStaging.removeAll(keepingCapacity: false)
        sealedStagingOrder.removeAll(keepingCapacity: false)
        _totalBytes = 0
        _highestStoredIndex = -1
        lastStore = nil
        paceSteps.removeAll()
        let pressureSource = memoryPressureSource
        memoryPressureSource = nil
        condition.broadcast()
        condition.unlock()

        pressureSource?.cancel()
        expiryTimer?.cancel()
        releaseLiveMarker()
        Self.discardQueue.async { try? FileManager.default.removeItem(at: dir) }
        // A closed cache holds nothing, and that is a resident-set change like any other. The engine
        // clears its published band on teardown anyway; this keeps the cache honest on its own.
        if hadEntries { onResidentSetChanged?() }
    }

    // MARK: - Reader side

    func declareTarget(_ index: Int) {
        condition.lock()
        var doomed: [StagedSegment] = []
        var memory: MemoryRebalance?
        trackFetchSequenceLocked(index)
        if index != currentTargetIndex {
            currentTargetIndex = index
            doomed = pruneOutsideWindow()
            memory = rebalanceMemoryLocked()
            condition.broadcast()
        }
        condition.unlock()
        for segment in doomed { segment.discard() }
        if let memory { finishRebalance(memory) }
        if !doomed.isEmpty || memory?.droppedEntries == true { onResidentSetChanged?() }
    }

    /// Must be called with condition held.
    ///
    /// A fetch that leaves a gap above the front, or that drops further back than a handover refetch
    /// reaches, is the consumer arriving from somewhere else: it flushed its buffer and starts a new
    /// sequence here. Anything else extends the current one, including the ~7-10 segment backward
    /// refetch of the Continuous-Audio handover and its return to the front, which must NOT count as a
    /// jump: under an opt-in prefetch the playhead sits below the retained low end, so falling back to
    /// the playhead anchor there would re-open the #207 collapse the anchor exists to prevent.
    private func trackFetchSequenceLocked(_ index: Int) {
        if index > fetchFront + 1 || index < fetchFront - backwardWindow {
            fetchFloor = index
            fetchFront = index
        } else {
            fetchFront = max(fetchFront, index)
        }
    }

    func peek(index: Int) -> Data? {
        guard let stored = storedSegment(index: index) else { return nil }
        return readOrDrop(index: index, stored: stored)
    }

    /// AE#451: the bookkeeping is not the bytes, and this is where the bookkeeping is redeemed.
    ///
    /// The segment at `index` if it is still there: a file that exists, or a memory segment the
    /// kernel has not emptied (review H2: a volatile one is asked, not reclaimed). Every caller reads
    /// the answer as "the segment is stored": the server serves it (a file that has gone answers a
    /// 404, which the #50 rule forbids for an in-range index and AVPlayer treats as terminal on VOD),
    /// the AE#421 wedge split asks it to tell a starved consumer from a silent one, and the byte
    /// ledger bills for it. So an entry whose bytes have gone stops answering here, and the producer
    /// is free to make it again.
    func storedSegment(index: Int) -> StagedSegment? {
        condition.lock()
        let entry = entries[index]
        condition.unlock()
        guard let stored = entry else { return nil }
        switch stored {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                dropVanishedEntry(index: index, key: stored.key, purged: false)
                return nil
            }
        case .memory(let buffer):
            guard !buffer.isEmptied else {
                dropVanishedEntry(index: index, key: stored.key, purged: true)
                return nil
            }
        }
        return stored
    }

    /// Whether the segment at `index` is stored, in a file or in memory (`storedSegment`).
    func isStored(index: Int) -> Bool {
        storedSegment(index: index) != nil
    }

    /// The segment's file when it is stored on disk, for the sendfile fast path and its logs; nil for
    /// a memory segment, which is served from `fetchSource`'s data. Not a residency check: that is
    /// `isStored` (review M4: the old `peekURL` answered both, and a memory segment must not read as
    /// missing).
    func fileURLIfOnDisk(index: Int) -> URL? {
        storedSegment(index: index)?.fileURL
    }

    /// Forget an entry whose bytes are gone. Keeps `_highestStoredIndex`: it records how far the
    /// producer got, which an external deletion or a purge does not undo.
    private func dropVanishedEntry(index: Int, key: StagedSegment.Key, purged: Bool) {
        condition.lock()
        guard entries[index]?.key == key else {
            condition.unlock()
            return
        }
        entries.removeValue(forKey: index)
        _totalBytes -= entryBytes.removeValue(forKey: index) ?? 0
        videoReaches.removeValue(forKey: index)
        if purged { _purgedSegments += 1 }
        condition.broadcast()
        condition.unlock()
        EngineLog.emit(purged
                       ? "[SegmentCache] seg-\(index) was purged from memory; entry dropped"
                       : "[SegmentCache] seg-\(index) vanished from disk; entry dropped (AE#451)",
                       category: .session)
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        if let stored = entries[index] {
            condition.unlock()
            return readOrDrop(index: index, stored: stored)
        }
        if closed {
            condition.unlock()
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        let entry = entries[index]
        condition.unlock()
        guard let stored = entry else { return nil }
        return readOrDrop(index: index, stored: stored)
    }

    // MARK: - Progressive delivery

    /// How many adoptions `sealedFromStaging` remembers: enough for every reader still draining.
    static let sealedStagingMemory = 64

    /// The producer opened segment `index` in `stagingPath`, which from here on is only appended to
    /// until it is adopted under its final name.
    func beginInProgress(index: Int, stagingPath: URL) {
        beginInProgress(index: index, staged: .file(stagingPath))
    }

    /// The producer opened segment `index` in `staged`, which from here on is only appended to until
    /// it is adopted.
    func beginInProgress(index: Int, staged: StagedSegment) {
        condition.lock()
        if !closed {
            inProgress[index] = staged
            condition.broadcast()
        }
        condition.unlock()
    }

    /// The producer gave up the segment it was writing (restart, failed cut, teardown), so its
    /// partial bytes are never adopted. A reader draining it learns that on its next poll; a memory
    /// buffer is freed once its last reader lets go.
    func abandonInProgress(index: Int) {
        condition.lock()
        if inProgress.removeValue(forKey: index) != nil { condition.broadcast() }
        condition.unlock()
    }

    enum InProgressState: Equatable {
        case writing
        case sealed(bytes: Int)
        case abandoned
    }

    /// What became of the staged bytes a progressive reader holds.
    func inProgressState(index: Int, key: StagedSegment.Key) -> InProgressState {
        condition.lock()
        defer { condition.unlock() }
        if inProgress[index]?.key == key { return .writing }
        if let bytes = sealedFromStaging[key] { return .sealed(bytes: bytes) }
        return .abandoned
    }

    func inProgressState(index: Int, stagingPath: URL) -> InProgressState {
        inProgressState(index: index, key: .file(stagingPath))
    }

    /// `fetch` for the loopback server. With `progressive`, a segment that is being written is
    /// answered at once with a reader over its staged bytes, so AVPlayer receives each fragment as
    /// the muxer flushes it instead of the whole segment after its cut.
    func fetchSource(index: Int, timeout: TimeInterval, progressive: Bool) -> SegmentSource? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while true {
            if let stored = entries[index] {
                condition.unlock()
                return readOrDrop(index: index, stored: stored).map { .data($0) }
            }
            if closed {
                condition.unlock()
                return nil
            }
            if progressive, let staging = inProgress[index] {
                condition.unlock()
                if let reader = ProgressiveSegmentReader(cache: self, index: index, staged: staging) {
                    return .progressive(reader)
                }
                // The staging file was renamed or removed between the lookup and the open: look again.
                condition.lock()
                if inProgress[index]?.key == staging.key { inProgress.removeValue(forKey: index) }
                continue
            }
            if !condition.wait(until: deadline) {
                condition.unlock()
                return nil
            }
        }
    }

    /// AE#451: a read that comes back empty for bytes the bookkeeping still lists is the same lie
    /// `storedSegment` guards against, and here it is load-bearing: this serve answers a retriable
    /// 503, and an entry left standing means every retry takes this branch again while the producer,
    /// which asks whether the segment is stored, is never told to make it. A memory segment's read
    /// reclaims it first and answers a pinned no-copy `Data` (review H2), or nil when it was purged.
    private func readOrDrop(index: Int, stored: StagedSegment) -> Data? {
        let data: Data?
        switch stored {
        case .file(let url): data = readMapped(url)
        case .memory(let buffer): data = buffer.pinnedData()
        }
        guard let data else {
            dropVanishedEntry(index: index, key: stored.key, purged: stored.fileURL == nil)
            return nil
        }
        return data
    }

    func fetchInit(timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let i = initSegment { return i }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, initSegment == nil {
            if !condition.wait(until: deadline) { break }
        }
        return initSegment
    }

    /// Pump-side backpressure: one-shot wait for target or any broadcast. Returns true if target met.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if currentTargetIndex >= target { return true }
        if closed { return false }
        let deadline = Date().addingTimeInterval(timeout)
        _ = condition.wait(until: deadline)
        return currentTargetIndex >= target
    }

    /// Evict segments strictly below cutoff, which the live caller bounds at the consumer's own fetch
    /// point (`VideoSegmentProvider.liveEvictionFloor`) so this never unlinks the segment a response is
    /// about to stat; pruneOutsideWindow handles the forward bound.
    func evictBelow(_ cutoff: Int) {
        condition.lock()
        var doomed: [StagedSegment] = []
        for (k, stored) in entries where k < cutoff {
            _totalBytes -= entryBytes[k] ?? byteSize(of: stored)
            entryBytes.removeValue(forKey: k)
            entries.removeValue(forKey: k)
            doomed.append(stored)
        }
        condition.unlock()
        for segment in doomed { segment.discard() }
        if !doomed.isEmpty { onResidentSetChanged?() }
    }

    /// Authoritative disk footprint via fresh stat (not _totalBytes accumulator); diagnostics path.
    /// Memory segments are not on disk and are not counted (`memoryBytes`).
    func diskBytes() -> Int64 {
        condition.lock()
        let urls = entries.values.compactMap(\.fileURL)
        condition.unlock()
        var total: Int64 = 0
        for url in urls {
            total += Int64(byteSize(of: url))
        }
        return total
    }

    /// Bytes of the segments stored in files, from the ledger: what the retention claim on the tmp
    /// volume bills (review L6), where `totalBytes` also counts memory segments.
    var storedDiskBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        var bytes = 0
        for (k, stored) in entries where stored.fileURL != nil { bytes += entryBytes[k] ?? 0 }
        return bytes
    }

    // MARK: - Memory segments (W3167)

    /// Counted memory (the lead and the segment being written) and the volatile memory behind it.
    func memoryBytes() -> (counted: Int, volatile: Int) {
        condition.lock()
        defer { condition.unlock() }
        var counted = inProgressMemoryBytesLocked()
        var volatile = 0
        for (k, stored) in entries {
            guard case .memory(let buffer) = stored else { continue }
            if buffer.isVolatile { volatile += entryBytes[k] ?? 0 } else { counted += entryBytes[k] ?? 0 }
        }
        return (counted, volatile)
    }

    /// Bytes this cache wrote to files since it opened: staging writes, `store`, spills.
    var bytesWrittenToDisk: Int {
        condition.lock()
        defer { condition.unlock() }
        return _bytesWrittenToDisk
    }

    /// The muxer wrote `bytes` to a staging file of this session.
    func noteBytesWrittenToDisk(_ bytes: Int) {
        condition.lock()
        _bytesWrittenToDisk += bytes
        condition.unlock()
    }

    var spilledSegments: Int {
        condition.lock()
        defer { condition.unlock() }
        return _spilledSegments
    }

    var purgedSegments: Int {
        condition.lock()
        defer { condition.unlock() }
        return _purgedSegments
    }

    /// Where the producer writes segment `index`: a memory buffer while the counted memory plus the
    /// next segment fits B, or nil for a staging file as before. Also where a shrunken B is noticed
    /// while the producer runs (review H3).
    func memorySegment(forIndex index: Int) -> SegmentMemoryBuffer? {
        condition.lock()
        guard memoryBudget != nil, !closed else {
            condition.unlock()
            return nil
        }
        let state = rebalanceMemoryLocked()
        let estimate = lastAdoptedBytes > 0 ? lastAdoptedBytes : 8 << 20
        let admits = !state.holdNew && state.counted + estimate <= state.budget
        condition.unlock()
        finishRebalance(state)
        return admits ? SegmentMemoryBuffer(expectedBytes: estimate) : nil
    }

    /// A memory-pressure event: nothing new to memory for `pressureHoldSeconds`, and the held memory
    /// spilled down to B / 2. Runs on `spillQueue`; tests call it directly.
    func noteMemoryPressure() {
        condition.lock()
        guard let budget = memoryBudget, !closed else {
            condition.unlock()
            return
        }
        lastPressureAt = budget.now()
        let state = rebalanceMemoryLocked()
        condition.unlock()
        EngineLog.emit("[SegmentCache] memory pressure: \(state.counted >> 20) MiB counted, "
                       + "budget \(state.budget >> 20) MiB, shrinking to \(state.goal >> 20) MiB",
                       category: .session)
        finishRebalance(state)
    }

    /// What one rebalance found: the counted memory after it, B, the goal a shrink aims for, whether
    /// new segments are held back from memory, and whether entries were dropped or a spill is needed.
    struct MemoryRebalance {
        var counted = 0
        var budget = 0
        var goal = 0
        var holdNew = false
        var droppedEntries = false
        var needsSpill = false
    }

    /// Must be called with condition held. Sets each memory segment's volatility from its place
    /// relative to the target, drops the ones the kernel emptied, caps the volatile history at B, and
    /// when the counted memory exceeds the goal makes the band behind the target volatile too.
    /// Spilling is left to `finishRebalance`, off the lock.
    private func rebalanceMemoryLocked() -> MemoryRebalance {
        var state = MemoryRebalance()
        guard let budget = memoryBudget else { return state }
        let target = currentTargetIndex
        let lo = target - Self.memoryKeepBehind
        let hi = max(target + forwardWindow, _highestStoredIndex)
        var counted = inProgressMemoryBytesLocked()
        var behindBand: [(index: Int, buffer: SegmentMemoryBuffer, bytes: Int)] = []
        var history: [(index: Int, bytes: Int)] = []
        var purged: [Int] = []
        for (k, stored) in entries {
            guard case .memory(let buffer) = stored else { continue }
            let bytes = entryBytes[k] ?? 0
            // Before the consumer's first fetch everything stored is the lead it will ask for.
            let inLead = target < 0 || (k >= lo && k <= hi)
            if inLead {
                if buffer.setWantsVolatile(false) {
                    counted += bytes
                    if target >= 0, k < target { behindBand.append((k, buffer, bytes)) }
                } else {
                    purged.append(k)
                }
            } else {
                buffer.setWantsVolatile(true)
                if buffer.isEmptied { purged.append(k) } else { history.append((k, bytes)) }
            }
        }
        state.budget = budget.bytes(heldBytes: counted)
        let recentPressure = lastPressureAt.map { budget.now() - $0 < budget.pressureHoldSeconds } ?? false
        state.holdNew = recentPressure || budget.isCritical
        state.goal = state.holdNew ? state.budget / 2 : state.budget
        if counted > state.goal {
            // Free without a write first: the handover cushion behind the target.
            for item in behindBand.sorted(by: { $0.index < $1.index }) where counted > state.goal {
                item.buffer.setWantsVolatile(true)
                counted -= item.bytes
                history.append((item.index, item.bytes))
            }
        }
        state.counted = counted
        state.needsSpill = counted > state.goal
        // Volatile memory costs no footprint but address space: keep the nearest B of it.
        var kept = 0
        for item in history.sorted(by: { abs($0.index - target) < abs($1.index - target) }) {
            if kept + item.bytes <= state.budget { kept += item.bytes } else { purged.append(item.index) }
        }
        for k in purged {
            guard entries.removeValue(forKey: k) != nil else { continue }
            _totalBytes -= entryBytes.removeValue(forKey: k) ?? 0
            videoReaches.removeValue(forKey: k)
            _purgedSegments += 1
            state.droppedEntries = true
        }
        return state
    }

    /// Must be called with condition held. The segment being written, when it is in memory (L2).
    private func inProgressMemoryBytesLocked() -> Int {
        var bytes = 0
        for stored in inProgress.values {
            if case .memory(let buffer) = stored { bytes += buffer.length }
        }
        return bytes
    }

    /// Off the lock: schedules a spill when the rebalance asked for one.
    private func finishRebalance(_ state: MemoryRebalance) {
        guard state.needsSpill else { return }
        condition.lock()
        let schedule = !spillScheduled && !closed
        if schedule { spillScheduled = true }
        condition.unlock()
        guard schedule else { return }
        spillQueue.async { [weak self] in self?.spillOverBudget() }
    }

    /// Writes the farthest-ahead counted memory segments to files until the counted memory is within
    /// the goal. Never the segment being written (it is not an entry yet, review M7). The entry swaps
    /// to the file only once it is written, and only if it is still the same buffer; a reader holding
    /// the buffer's pinned bytes keeps them until it lets go.
    private func spillOverBudget() {
        condition.lock()
        let state = rebalanceMemoryLocked()
        var over = state.counted - state.goal
        var victims: [(index: Int, buffer: SegmentMemoryBuffer)] = []
        if over > 0 {
            for k in entries.keys.sorted(by: >) where over > 0 {
                guard case .memory(let buffer) = entries[k], !buffer.isVolatile else { continue }
                victims.append((k, buffer))
                over -= entryBytes[k] ?? 0
            }
        }
        spillScheduled = false
        condition.unlock()

        var spilled = 0
        for victim in victims {
            guard let data = victim.buffer.pinnedData() else { continue }
            let url = nextSegmentFileURL(index: victim.index)
            do {
                try data.write(to: url)
            } catch {
                EngineLog.emit("[SegmentCache] spill of seg-\(victim.index) failed: \(error)", category: .session)
                if Self.isOutOfSpace(error) { noteStorageExhausted() }
                try? FileManager.default.removeItem(at: url)
                break
            }
            condition.lock()
            _bytesWrittenToDisk += data.count
            let current = entries[victim.index]
            let swapped = !closed && current?.key == StagedSegment.memory(victim.buffer).key
            if swapped {
                entries[victim.index] = .file(url)
                _spilledSegments += 1
                spilled += 1
            }
            condition.unlock()
            if !swapped { try? FileManager.default.removeItem(at: url) }
        }
        if spilled > 0 {
            EngineLog.emit("[SegmentCache] spilled \(spilled) memory segment(s) to disk: "
                           + "\(state.counted >> 20) MiB counted over a \(state.goal >> 20) MiB goal",
                           category: .session)
        }
    }

    /// Waits for a scheduled spill to finish. Tests only.
    func drainSpillsForTesting() {
        spillQueue.sync {}
    }

    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Diagnostics

    var targetIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentTargetIndex
    }

    /// How often a pump has passed a plan index without opening a segment for it (#358).
    ///
    /// The keyframe-gated cutter opens a segment at the IRAP that reaches a boundary, so a boundary
    /// no IRAP reaches is stepped over while the playlist keeps offering it. One fold is not proof of
    /// a dead index: a re-anchor rebases the producer, which moves the boundaries, and the index can
    /// come out producible (measured: a re-anchor at a different base filled exactly such a gap).
    /// A SECOND fold of the same index is the proof, because it is the recovery reproducing its own
    /// trigger. Cleared by `adopt` when the index does arrive.
    func foldCount(_ index: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return foldCounts[index] ?? 0
    }

    /// AE#412: what the stored segment at `index` offers a cold arrival, or nil when nothing was
    /// recorded for it (live, or a producer that could not resolve its time base). A caller must not
    /// read nil as "unreachable": an unrecorded segment is exactly today's behaviour, not a defect.
    func videoReach(_ index: Int) -> VideoReach? {
        condition.lock()
        defer { condition.unlock() }
        guard entries[index] != nil else { return nil }
        return videoReaches[index]
    }

    /// Record plan indices a cut jumped over. VOD only: a live playlist is built from what was
    /// finalized, so it never offers an index the pump skipped.
    /// #369: runs wider than `maxFoldRunLength` count too, the #358 arms exist precisely for a
    /// consumer that requests a folded index, and the widest folds are the ones most certain to
    /// produce such a request. Memory is one Int per folded index, bounded by the plan size.
    func noteFolded(_ indices: Range<Int>) {
        guard !indices.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        for index in indices where entries[index] == nil {
            foldCounts[index, default: 0] += 1
        }
    }

    func indexRange() -> (Int, Int)? {
        condition.lock()
        defer { condition.unlock() }
        dropEmptiedMemoryLocked()
        guard !entries.isEmpty else { return nil }
        let keys = entries.keys
        return (keys.min()!, keys.max()!)
    }

    /// Contiguous runs of segment indexes that are resident, in files or in memory. A 2026-09-02 field session
    /// retained 64 segments across several islands, so min/max alone cannot describe the picture
    /// a host can truthfully mark as loaded.
    func residentIndexRanges() -> [ClosedRange<Int>] {
        condition.lock()
        defer { condition.unlock() }
        dropEmptiedMemoryLocked()
        let indexes = entries.keys.sorted()
        guard let first = indexes.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var lower = first
        var upper = first
        for index in indexes.dropFirst() {
            if index == upper + 1 {
                upper = index
            } else {
                ranges.append(lower...upper)
                lower = index
                upper = index
            }
        }
        ranges.append(lower...upper)
        return ranges
    }

    /// Monotonic across prunes; reset per restart via resetHighWaterForRestart().
    /// indexRange() only shows resident entries and loses the signal after pruning the high end;
    /// highestStoredIndex retains it so VideoSegmentProvider can detect prune-created gaps.
    var highestStoredIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return _highestStoredIndex
    }

    /// The producer's pace, under `condition`: the last segment stored (nil after a park) and the recent steps from
    /// one segment to the next, with when each was taken (`fastestRecentSegmentSeconds`).
    private var lastStore: (index: Int, at: Double)?
    private var paceSteps: [(seconds: Double, at: Double)] = []

    private func noteStoreLocked(_ index: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastStore, index == last.index + 1, now > last.at {
            paceSteps.append((now - last.at, now))
            if paceSteps.count > 4 { paceSteps.removeFirst(paceSteps.count - 4) }
        }
        lastStore = (index, now)
    }

    /// The producer parked: the step to the next segment it stores waited on playback, so it says nothing of the
    /// source's pace and is left out.
    func noteMarchParked() {
        condition.lock()
        lastStore = nil
        condition.unlock()
    }

    /// How long the producer takes per segment when it is not waiting on playback: the quickest of its last few
    /// steps from one segment to the next taken in the last two minutes. Nil when there is none.
    var fastestRecentSegmentSeconds: Double? {
        condition.lock()
        defer { condition.unlock() }
        return Self.fastestStep(paceSteps, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The pump's read rate while it is not parked, in bytes a second, and when it was taken (`notePumpRate`).
    private var pumpRate: (bytesPerSecond: Double, at: Double)?

    /// The pump's read rate in bytes a second, nil when it is older than five seconds (`notePumpRate`).
    var currentPumpRate: Double? {
        condition.lock()
        defer { condition.unlock() }
        guard let rate = pumpRate, ProcessInfo.processInfo.systemUptime - rate.at <= 5 else { return nil }
        return rate.bytesPerSecond
    }

    /// The producer read `bytesPerSecond` over its last stretch without a park.
    func notePumpRate(bytesPerSecond: Double) {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return }
        condition.lock()
        pumpRate = (bytesPerSecond, ProcessInfo.processInfo.systemUptime)
        condition.unlock()
    }

    /// How long the producer takes per segment: its quickest recent step (`fastestRecentSegmentSeconds`), else,
    /// before it has two consecutive stores, the segments stored so far at its current read rate. The second is what
    /// a request coming right after a start or a restart has (a DV clip's first seg5 request waited 3 s for the
    /// second store on the device). Nil when neither is known.
    var estimatedSecondsPerSegment: Double? {
        condition.lock()
        defer { condition.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let step = Self.fastestStep(paceSteps, now: now) { return step }
        return Self.secondsPerSegment(storedBytes: Array(entryBytes.values), pumpRate: pumpRate, now: now)
    }

    nonisolated static func secondsPerSegment(storedBytes: [Int], pumpRate: (bytesPerSecond: Double, at: Double)?,
                                              now: Double, maxAge: Double = 5) -> Double? {
        guard let rate = pumpRate, now - rate.at <= maxAge, rate.bytesPerSecond > 0, !storedBytes.isEmpty else {
            return nil
        }
        let average = Double(storedBytes.reduce(0, +)) / Double(storedBytes.count)
        return average / rate.bytesPerSecond
    }

    nonisolated static func fastestStep(_ steps: [(seconds: Double, at: Double)], now: Double,
                                        maxAge: Double = 120) -> Double? {
        steps.filter { now - $0.at <= maxAge }.map(\.seconds).min()
    }

    /// Largest K such that every index in [startIdx ... K] is resident, walking forward until the first
    /// gap. Returns startIdx - 1 when startIdx itself is absent (nothing cached from there). Used to
    /// express the disk read-ahead frontier as a segment index. Thread-safe.
    func contiguousForwardFrontier(from startIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return frontierLocked(from: startIdx)
    }

    /// Frontier of the contiguous *safe* range for a playhead at `playheadIdx`, anchored at
    /// `max(playheadIdx, currentTargetIndex)` (#207 follow-up).
    ///
    /// Walking from the playhead alone under-reports whenever the consumer's fetch target runs ahead of
    /// it: `pruneOutsideWindow` retains from `currentTargetIndex - backwardWindow` upward, so the
    /// playhead's own segment is an evictable extra, and an opt-in whole-source prefetch (which is the
    /// only case that reaches the retention budget) really does evict it. The walk then starts on a hole
    /// and reports nothing ahead while the whole band is resident.
    ///
    /// Anchoring on the fetch target is safe rather than merely optimistic: `declareTarget` is only ever
    /// called from the segment-serve path, so everything below `currentTargetIndex` has been handed to
    /// the consumer and sits in its own buffer. Skipping the leading hole *without* that bound would
    /// instead land on a stale band above a backward seek (nothing forces its eviction while the budget
    /// has room) and report it as buffered, which fails in the dangerous direction; anchoring at the new
    /// target stops the walk at the hole above the freshly produced segments. `max` keeps a backward
    /// refetch behind the playhead (Continuous-Audio handover) from dragging the anchor back.
    ///
    /// Anchor and walk share one lock hold: reading `targetIndex` separately would let a target change
    /// land between the two and walk from an anchor that does not match the entries observed.
    ///
    /// The target anchor only holds while the playhead is inside the consumer's current fetch sequence.
    /// AVPlayer fetches no further ahead than its own buffer reaches, which is what keeps everything
    /// between the playhead and the target genuinely held; a seek removes that bound, and since
    /// `declareTarget` lands at the destination before `currentTime()` reports it, the target would
    /// otherwise measure the band at the destination against the position the seek jumped away from and
    /// claim a lead the size of the seek distance (#207 field report on 5.23.4). Outside the sequence the
    /// walk falls back to the playhead, which reports the band that is genuinely reachable from there,
    /// or nothing when its own segment is gone.
    func contiguousForwardFrontier(fromPlayhead playheadIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let anchor = playheadIdx >= fetchFloor ? max(playheadIdx, currentTargetIndex) : playheadIdx
        return frontierLocked(from: anchor)
    }

    /// Must be called with condition held.
    private func frontierLocked(from startIdx: Int) -> Int {
        dropEmptiedMemoryLocked()
        var k = startIdx
        while entries[k] != nil { k += 1 }
        return k - 1
    }

    /// AE#441: the mirror of `contiguousForwardFrontier`, walking DOWN. Smallest K such that every index
    /// in `K ... topIdx` is resident, or `topIdx + 1` when `topIdx` itself is absent (nothing to walk).
    ///
    /// This, not `indexRange().0`, is the honest floor of a rewind: `min ... max` is not proof of
    /// residency, because retained scrub bands leave interior holes (the same reason the segment-serve
    /// path refuses to treat that range as coverage). A floor advertised below a hole promises a rewind
    /// that cannot then play forward.
    func contiguousBackwardFloor(from topIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        dropEmptiedMemoryLocked()
        var k = topIdx
        while entries[k] != nil { k -= 1 }
        return k + 1
    }

    /// AE#441: the newest resident index, which is where a backward floor walk starts. `highestStoredIndex`
    /// is monotonic across prunes and would start the walk on a hole after the high end is pruned.
    var highestResidentIndex: Int? {
        condition.lock()
        defer { condition.unlock() }
        dropEmptiedMemoryLocked()
        return entries.keys.max()
    }

    /// Reset before triggering a restart; previous producer's highWater would keep producerPassedAndPruned
    /// hot on every fetch, cascading a single restart into a per-segment storm.
    func resetHighWaterForRestart() {
        condition.lock()
        defer { condition.unlock() }
        _highestStoredIndex = -1
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    /// Bytes of every stored segment, in files and in memory (`storedDiskBytes`, `memoryBytes`).
    var totalBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalBytes
    }

    /// AE#443: mean on-disk size of a resident segment, which is what turns a window in seconds into a
    /// window in bytes (`LiveWindowSizing.affordableSegments`). nil while nothing is resident, so an
    /// empty cache states that it cannot answer rather than answering zero.
    var meanEntryBytes: Int? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty, _totalBytes > 0 else { return nil }
        return Int(_totalBytes) / entries.count
    }

    /// On-disk bytes at or above the consumer's current target: what the producer's race-ahead owns
    /// (#207). Everything behind the playhead is either the small backward window or budget-evictable
    /// extras, so this is the only footprint an opt-in whole-source window grows without bound.
    var forwardBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentForwardBytes()
    }

    /// #207 producer park step: true once the producer may write `head`. Withheld while its race-ahead
    /// has reached `budgetBytes` and the consumer still has a safe lead behind it; the extras eviction
    /// that follows the advancing playhead is what frees the room again.
    func awaitPrefetchDiskHeadroom(head: Int, budgetBytes: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !shouldParkLocked(head: head, budgetBytes: budgetBytes) { return true }
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        return !shouldParkLocked(head: head, budgetBytes: budgetBytes)
    }

    /// Must be called with condition held.
    private func shouldParkLocked(head: Int, budgetBytes: Int) -> Bool {
        PrefetchDiskBudget.shouldPark(forwardBytes: currentForwardBytes(),
                                      budgetBytes: budgetBytes,
                                      head: head,
                                      consumerTarget: currentTargetIndex)
    }

    /// Must be called with condition held.
    /// The segment being written counts when it is in memory (review L2: a burst segment larger than
    /// the last one must not pass unseen).
    private func currentForwardBytes() -> Int {
        var bytes = inProgressMemoryBytesLocked()
        for (k, b) in entryBytes where k >= currentTargetIndex { bytes += b }
        return bytes
    }

    /// Metadata-only admission from the host setter. Exactly one weakly-owned timer per opted-in
    /// cache; it progresses even when the pump is parked and AVPlayer makes no playlist requests.
    func startNativeLiveDVRExpiryChecks() {
        condition.lock()
        guard !closed, nativeLiveDVRPolicy != nil, nativeLiveExpiryTimer == nil else {
            condition.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: nativeLiveExpiryQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in _ = self?.reconcileExpiredNativeLiveDVRRetention() }
        nativeLiveExpiryTimer = timer
        timer.resume()
        condition.unlock()
    }

    /// Both the independent timer and the producer use this implementation. The cap is evaluated
    /// by the caller FIRST; then expiry pruning and the current entry count share this lock hold.
    /// An expired smaller cap cannot park a pump behind unpruned expanded history.
    @discardableResult
    func reconcileExpiredNativeLiveDVRRetention(headroomCap: Int? = nil) -> Bool {
        condition.lock()
        guard !closed else { condition.unlock(); return false }
        let expiredOrDenied = nativeLiveDVRPolicy?.snapshot?.retentionBytes == 0
        let doomed = expiredOrDenied ? pruneOutsideWindow() : []
        let hasHeadroom = headroomCap.map { entries.count < $0 } ?? true
        if !doomed.isEmpty { condition.broadcast() }
        condition.unlock()
        for segment in doomed { segment.discard() }
        if !doomed.isEmpty { onResidentSetChanged?() }
        return hasHeadroom
    }

    /// Called off the main actor after a native limit update and each finalized live segment.
    func applyNativeLiveRetentionFloor(_ floor: Int) {
        condition.lock()
        nativeLiveRetentionFloor = max(nativeLiveRetentionFloor, floor)
        let doomed = pruneOutsideWindow()
        condition.broadcast()
        condition.unlock()
        for segment in doomed { segment.discard() }
        if !doomed.isEmpty { onResidentSetChanged?() }
    }

    /// The finite exception consists of the consumer's existing handover/prefetch band and
    /// eight newest segments. No unbounded `[target ... highestStoredIndex]` exception for live.
    private func isNativeLiveMandatory(_ index: Int) -> Bool {
        let consumer = currentTargetIndex >= 0 &&
            index >= currentTargetIndex - backwardWindow && index <= currentTargetIndex + forwardWindow
        return consumer || index > _highestStoredIndex - LiveWindowSizing.minSafeSegments
    }

    var nativeLiveMandatoryBytes: Int {
        condition.lock(); defer { condition.unlock() }
        return entryBytes.reduce(0) { $0 + (isNativeLiveMandatory($1.key) ? $1.value : 0) }
    }

    // MARK: - Internal

    /// Prune to [currentTarget - backwardWindow, max(currentTarget + forwardWindow, highestStoredIndex)].
    /// Must be called with condition held.
    /// hi anchors on highestStoredIndex so a transient backward refetch (AVPlayer audio handover)
    /// doesn't evict already-produced forward segments (repro: seg0..25 produced, refetch seg4 -> target=4
    /// pruned seg15+, stalled when playback reached seg15).
    /// With a retention budget (#93 / Sodalite#32), entries outside that hard window survive,
    /// nearest-to-target first, while the cache's total footprint fits the budget; the window itself
    /// is never evicted even when it alone exceeds the budget. Nearest-first eviction from the far
    /// ends keeps each side of the resident span contiguous, so the provider's residency gate
    /// (a resident backward target = no producer restart) holds across the whole retained span.
    private func pruneOutsideWindow() -> [StagedSegment] {
        if let limits = nativeLiveDVRPolicy?.snapshot {
            var keptBytes = entryBytes.reduce(0) { $0 + (isNativeLiveMandatory($1.key) ? $1.value : 0) }
            var doomed: [StagedSegment] = []
            // Newest-first produces a contiguous playable suffix, even when an older consumer
            // band must remain pinned. The published DVR range already walks this suffix.
            for index in entries.keys.sorted(by: >) where !isNativeLiveMandatory(index) {
                let bytes = entryBytes[index] ?? 0
                if index >= nativeLiveRetentionFloor && bytes <= max(0, limits.retentionBytes - keptBytes) {
                    keptBytes += bytes
                } else if let stored = entries.removeValue(forKey: index) {
                    _totalBytes -= bytes
                    entryBytes.removeValue(forKey: index)
                    videoReaches.removeValue(forKey: index)
                    doomed.append(stored)
                }
            }
            return doomed
        }
        let lo = currentTargetIndex - backwardWindow
        let hi = max(currentTargetIndex + forwardWindow, _highestStoredIndex)
        var doomed: [StagedSegment] = []
        if retentionBudgetBytes > 0 {
            var extras: [(index: Int, bytes: Int)] = []
            var keptBytes = 0
            for (k, _) in entries {
                let bytes = entryBytes[k] ?? 0
                if k < lo || k > hi {
                    extras.append((k, bytes))
                } else {
                    keptBytes += bytes
                }
            }
            guard !extras.isEmpty else { return [] }
            extras.sort { abs($0.index - currentTargetIndex) < abs($1.index - currentTargetIndex) }
            for (k, bytes) in extras {
                if keptBytes + bytes <= retentionBudgetBytes {
                    keptBytes += bytes
                } else if let stored = entries[k] {
                    _totalBytes -= bytes
                    entryBytes.removeValue(forKey: k)
                    entries.removeValue(forKey: k)
                    videoReaches.removeValue(forKey: k)
                    doomed.append(stored)
                }
            }
            return doomed
        }
        for (k, stored) in entries {
            if k < lo || k > hi {
                _totalBytes -= entryBytes[k] ?? byteSize(of: stored)
                entryBytes.removeValue(forKey: k)
                entries.removeValue(forKey: k)
                videoReaches.removeValue(forKey: k)
                doomed.append(stored)
            }
        }
        // Collected under the lock, deleted by the caller AFTER
        // unlocking: removeItem is filesystem I/O on the segment-serve
        // hot path (fetch waiters + the pump's backpressure wait park on
        // this condition; PacketRingBuffer's eviction uses the same
        // pattern). A racing reader that still resolves a doomed URL
        // degrades to an mmap miss -> nil, same as before.
        return doomed
    }

    /// Read a segment file as mmap-backed Data. The kernel pages in
    /// on access and frees on memory pressure; we never hold the
    /// full segment in our heap. Errors degrade to `nil` (cache miss);
    /// the caller handles that by retrying or restarting the producer.
    private func readMapped(_ url: URL) -> Data? {
        do {
            return try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        } catch {
            EngineLog.emit("[SegmentCache] mmap read failed \(url.lastPathComponent): \(error)",
                           category: .session)
            return nil
        }
    }

    /// On-disk size of a segment file. Cached size accounting only
    /// queries the file system when needed; in steady state `store`
    /// + `prune` keep `_totalBytes` accurate via Data.count and this
    /// path is a fallback.
    private func byteSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func byteSize(of stored: StagedSegment) -> Int {
        switch stored {
        case .file(let url): return byteSize(of: url)
        case .memory(let buffer): return buffer.length
        }
    }

    /// Must be called with condition held. Forgets the memory segments the kernel emptied (review
    /// M2), so the residency walks never count purged content as resident: a frontier that walked
    /// over one kept the producer for a back-seek whose consumer then met a 503 and restarted with an
    /// empty buffer (AE#408). One `vm_purgable_control` query per volatile segment. The resident-set
    /// callback is not called from here: these walks run inside the callback's own readers; the next
    /// store, target change or prune reports the set.
    private func dropEmptiedMemoryLocked() {
        guard memoryBudget != nil else { return }
        for (k, stored) in entries {
            guard case .memory(let buffer) = stored, buffer.isVolatile, buffer.isEmptied else { continue }
            entries.removeValue(forKey: k)
            _totalBytes -= entryBytes.removeValue(forKey: k) ?? 0
            videoReaches.removeValue(forKey: k)
            _purgedSegments += 1
        }
    }
}

/// A segment as the loopback server gets it: complete bytes, or a reader over one being written.
enum SegmentSource {
    case data(Data)
    case progressive(ProgressiveSegmentReader)
}

/// Reads a segment while its producer is still writing it.
///
/// The muxer appends each flushed fragment (moof+mdat) to the staged bytes and never rewrites what
/// it wrote, and adoption takes them as they stand. So a reader reads a growing prefix of the final
/// segment, adoption does not disturb it, and the read is complete at the byte count the cache
/// records for the adoption. A segment the producer abandons reads as `.abandoned`, and the server
/// closes the connection so AVPlayer asks for it again.
///
/// Concurrency (review M7): a staging file is ordered by the kernel (`fstat` then `pread` on its own
/// descriptor, which a rename does not disturb). A memory buffer is appended to on the producer's
/// thread while this reads on a server thread; both go through the buffer's lock, its length grows
/// only after the bytes are in place, and a read copies under that lock, so a reader never sees a
/// length ahead of its bytes nor holds a region a growing append replaced. The reader keeps the
/// buffer alive, so an abandoned segment's bytes are freed when its last reader lets go. A spill
/// never picks the segment being written (it is not an entry until adopted).
final class ProgressiveSegmentReader: @unchecked Sendable {
    let index: Int
    let staged: StagedSegment
    private let fd: Int32
    private weak var cache: SegmentCache?
    private(set) var offset: Int64 = 0

    enum Next: Equatable {
        case bytes(Data)
        case finished
        case abandoned
    }

    convenience init?(cache: SegmentCache, index: Int, stagingPath: URL) {
        self.init(cache: cache, index: index, staged: .file(stagingPath))
    }

    init?(cache: SegmentCache, index: Int, staged: StagedSegment) {
        switch staged {
        case .file(let url):
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return nil }
            self.fd = fd
        case .memory:
            self.fd = -1
        }
        self.cache = cache
        self.index = index
        self.staged = staged
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Bytes written so far; nil when a memory segment was emptied.
    private func writtenLength() -> Int64? {
        switch staged {
        case .file:
            var st = stat()
            return fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
        case .memory(let buffer):
            return buffer.isEmptied ? nil : Int64(buffer.length)
        }
    }

    /// Up to `maxBytes` past `offset`: empty when nothing new is written, nil when the bytes are gone.
    private func readAvailable(maxBytes: Int) -> Data? {
        switch staged {
        case .file:
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_size > offset else { return Data() }
            let count = Int(min(Int64(maxBytes), st.st_size - offset))
            var data = Data(count: count)
            let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            guard read > 0 else { return Data() }
            if read < count { data.removeSubrange(read ..< count) }
            return data
        case .memory(let buffer):
            return buffer.copyBytes(from: Int(offset), maxBytes: maxBytes)
        }
    }

    /// The next bytes past `offset`, waiting for the producer to write them. `.finished` once the
    /// sealed segment is read to its end; `.abandoned` when the producer gave it up, its memory was
    /// emptied, or it wrote nothing for `idleTimeout` (a wedged producer must not hold a connection
    /// forever).
    func next(maxBytes: Int = 256 * 1024, pollInterval: TimeInterval = 0.02,
              idleTimeout: TimeInterval = 60) -> Next {
        let deadline = Date().addingTimeInterval(idleTimeout)
        while true {
            guard let data = readAvailable(maxBytes: maxBytes) else { return .abandoned }
            if !data.isEmpty {
                offset += Int64(data.count)
                return .bytes(data)
            }
            switch cache?.inProgressState(index: index, key: staged.key) ?? .abandoned {
            case .writing:
                break
            case .sealed(let bytes):
                if offset >= Int64(bytes) { return .finished }
                // The last fragment can land with the seal, after the read above, so look again and
                // read on. Staged bytes shorter than their recorded size are not a state to spin in.
                if let length = writtenLength(), length > offset { continue }
                return .abandoned
            case .abandoned:
                return .abandoned
            }
            if Date() >= deadline { return .abandoned }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Reads to the seal, for a caller that needs the whole segment. nil when it was abandoned.
    func readToEnd() -> Data? {
        var all = Data()
        while true {
            switch next() {
            case .bytes(let d): all.append(d)
            case .finished: return all
            case .abandoned: return nil
            }
        }
    }
}
