import Darwin
import Foundation

/// AE#451: the liveness half of the `aether-segments/` stale-session sweep. A session directory's
/// creation date is its session's START time, so age alone cannot tell a session an hour in from one
/// that crashed an hour ago; an flock(2) held on `<dir>/session.lock` for the owner's lifetime can.
///
/// flock and not fcntl: flock locks belong to the open file description, so a second owner in the
/// SAME process fails to take it too. fcntl locks are per-process and a process never blocks itself.
/// The kernel drops the lock when the process dies, so a crashed session leaves an unheld marker and
/// sweeps as before.
///
/// Audit SEG-105: shared by `SegmentCache` and the software DVR ring, which lives under the same base
/// directory and was swept an hour into a DVR session because its directory carried no marker.
enum SessionDirectoryLiveness {
    static let markerName = "session.lock"

    /// The held marker's descriptor, or -1 when open or flock failed (such a directory is swept by
    /// age, the pre-AE#451 behaviour rather than a new failure).
    ///
    /// The marker is locked under a private name and then renamed into place, so `session.lock` never
    /// exists unheld while its owner lives: the sweep takes an unheld marker for a dead owner at any age.
    static func acquire(sessionDir: URL, logPrefix: String) -> Int32 {
        let path = sessionDir.appendingPathComponent(markerName).path
        let staging = sessionDir.appendingPathComponent(".\(markerName).\(UUID().uuidString)").path
        let fd = open(staging, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            EngineLog.emit("\(logPrefix) live marker open failed at \(path): errno=\(errno)",
                           category: .session)
            return -1
        }
        // Locked, put in place and registered in one step under the registry's lock, so a host letting
        // go meanwhile either finds it registered and lets go of it, or is seen letting go and no lock
        // is taken at all (Codex's review of zool/suspend-locks, 1).
        let held = takeHold(fd) {
            guard rename(staging, path) == 0 else {
                EngineLog.emit("\(logPrefix) live marker rename failed at \(path): errno=\(errno)",
                               category: .session)
                return false
            }
            return true
        }
        guard held else {
            EngineLog.emit("\(logPrefix) live marker lock failed at \(path): errno=\(errno)",
                           category: .session)
            Darwin.close(fd)
            unlink(staging)
            return -1
        }
        return fd
    }

    // MARK: - A host leaving the foreground (0xdead10cc)

    /// The markers this process holds, by descriptor, with the file each one is: `SegmentCache`'s,
    /// the DVR ring's and the software FIFO's `session.lock`. An app suspended while it holds a file
    /// lock is killed (RunningBoard's 0xdead10cc; an iPad app on a Mac, with a player open while its
    /// window was away: Zool's TestFlight 3203 and 5162). A host lets them go as it leaves the
    /// foreground and takes them back as it returns (`AetherEngine.releaseSessionLocks`); meanwhile
    /// this process's own sweeps read a registered marker as held, so none of its sessions loses its
    /// folder.
    ///
    /// One protocol under `registryLock`: a marker's lock, its publication and its registration; the
    /// host's letting go and taking back; and every sweep's liveness decision (the registry's word and
    /// the lock's probe). So no sweep sees a marker between its owner's registration and its unlock,
    /// and no acquisition keeps a lock through a let go.
    ///
    /// The assumption: one engine process per temporary folder, as every sandboxed app has (its
    /// container's tmp on iOS, tvOS, visionOS and a sandboxed Mac app). Another process sweeping the
    /// same folder would read a let-go marker as a dead session's; a non-sandboxed Mac host that runs
    /// two processes on one folder should not let go (docs/architecture.md).
    private struct Marker {
        var device: dev_t
        var inode: ino_t
    }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registered: [Int32: Marker] = [:]
    nonisolated(unsafe) private static var lettingGo = false
    /// Registered markers whose lock a take back could not take (another process's probe that
    /// instant): tried again at the next return and at the next session's acquisition.
    nonisolated(unsafe) private static var notTakenBack: Set<Int32> = []

    /// TEST-ONLY: run under the registry's lock, after an acquisition's flock and before its
    /// registration, and in a sweep's decision between the registry's word and the lock's probe.
    nonisolated(unsafe) static var holdHookForTesting: (() -> Void)?
    nonisolated(unsafe) static var probeHookForTesting: (() -> Void)?

    /// Locks `fd` (unless the host is away, when no lock is taken), runs `publish` (the marker's
    /// rename into place), and registers it, as one step; false when the lock or `publish` failed,
    /// with nothing held or registered.
    static func takeHold(_ fd: Int32, publish: () -> Bool) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        if !lettingGo { retakePending() }
        let locks = !lettingGo
        if locks {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
            holdHookForTesting?()
        }
        guard publish() else {
            if locks { flock(fd, LOCK_UN) }
            return false
        }
        registerLocked(fd)
        return true
    }

    /// Registers a marker locked by its owner already (a lease handed in): let go of at once while the
    /// host is away.
    static func adopt(_ fd: Int32) {
        registryLock.lock()
        defer { registryLock.unlock() }
        registerLocked(fd)
    }

    private static func registerLocked(_ fd: Int32) {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return }
        registered[fd] = Marker(device: info.st_dev, inode: info.st_ino)
        if lettingGo { flock(fd, LOCK_UN) }
    }

    /// Closes a held marker's descriptor, out of the registry first (a later descriptor may reuse its
    /// number).
    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        registryLock.lock()
        registered[fd] = nil
        notTakenBack.remove(fd)
        registryLock.unlock()
        Darwin.close(fd)
    }

    /// Whether the marker open at `fd` is one this process holds, its lock let go or not.
    static func isRegistered(_ fd: Int32) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return isRegisteredLocked(fd)
    }

    private static func isRegisteredLocked(_ fd: Int32) -> Bool {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return false }
        return registered.values.contains { $0.device == info.st_dev && $0.inode == info.st_ino }
    }

    /// A sweep's probe of a marker open at `fd`, under the registry's lock: `taken` leaves the sweep
    /// holding its lock (nobody else does, and this process has not registered it), `live` and `failed`
    /// leave nothing held.
    enum SweepProbe { case taken, live, failed }

    static func probeForSweep(_ fd: Int32) -> SweepProbe {
        registryLock.lock()
        defer { registryLock.unlock() }
        if isRegisteredLocked(fd) { return .live }
        probeHookForTesting?()
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK || errno == EAGAIN ? .live : .failed
        }
        return .taken
    }

    static func letGo() {
        registryLock.lock()
        defer { registryLock.unlock() }
        lettingGo = true
        notTakenBack.removeAll()
        for fd in registered.keys { flock(fd, LOCK_UN) }
    }

    static func takeBack() {
        registryLock.lock()
        defer { registryLock.unlock() }
        lettingGo = false
        notTakenBack = Set(registered.keys)
        retakePending()
    }

    /// How many registered markers are without their lock while the host is here: a take back that
    /// failed and has not been retried yet. For the host's diagnostics.
    static var notTakenBackCount: Int {
        registryLock.lock()
        defer { registryLock.unlock() }
        return lettingGo ? 0 : notTakenBack.count
    }

    private static func retakePending() {
        for fd in notTakenBack where flock(fd, LOCK_EX | LOCK_NB) == 0 { notTakenBack.remove(fd) }
        if !notTakenBack.isEmpty {
            // Another process's sweep probing them this instant; still registered, so this process's
            // sweeps keep them, and the next return or acquisition tries again.
            EngineLog.emit("[SessionDirectoryLiveness] \(notTakenBack.count) live marker(s) not taken back: errno=\(errno)",
                           category: .session)
        }
    }

    enum State {
        /// Some open file description holds the marker: the owner is alive.
        case held
        /// The marker is there and nobody holds it: the owner is gone (killed, crashed, closed).
        case free
        /// No marker: a directory from a build without one, or one whose owner has not locked yet
        /// (a DVR ring's directory exists before its marker). Only age can decide it.
        case unmarked
    }

    static func state(_ entry: URL) -> State {
        let path = entry.appendingPathComponent(markerName).path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .unmarked }
        defer { Darwin.close(fd) }
        // One of this process's own, its lock let go while the host is away (`letGo`): decided with
        // the probe under the registry's lock (Codex's review of zool/suspend-locks, 2).
        switch probeForSweep(fd) {
        case .taken:
            flock(fd, LOCK_UN)
            return .free
        case .live, .failed:
            return .held
        }
    }

    /// Whether some open file description still holds `entry`'s marker. A missing marker answers
    /// false: it is a directory from a build without one, and the age check decides it as before.
    static func isLive(_ entry: URL) -> Bool { state(entry) == .held }
}
