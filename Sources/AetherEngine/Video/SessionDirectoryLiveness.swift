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
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            EngineLog.emit("\(logPrefix) live marker lock failed at \(path): errno=\(errno)",
                           category: .session)
            Darwin.close(fd)
            unlink(staging)
            return -1
        }
        guard rename(staging, path) == 0 else {
            EngineLog.emit("\(logPrefix) live marker rename failed at \(path): errno=\(errno)",
                           category: .session)
            Darwin.close(fd)
            unlink(staging)
            return -1
        }
        register(fd)
        return fd
    }

    // MARK: - A host leaving the foreground (0xdead10cc)

    /// The markers this process holds, by descriptor, with the file each one is: `SegmentCache`'s,
    /// the DVR ring's and the software FIFO's `session.lock`. An app suspended while it holds a file
    /// lock is killed (RunningBoard's 0xdead10cc; an iPad app on a Mac, with a player open while its
    /// window was away: Zool's TestFlight 3203 and 5162). A host lets them go as it leaves the
    /// foreground and takes them back as it returns (`AetherEngine.releaseSessionLocks`); meanwhile
    /// this process's own sweeps read a registered marker as held, so none of its sessions loses its
    /// folder. Only another process could take a let-go marker for a dead one, and none shares an app's
    /// temporary folder on iOS, tvOS or visionOS.
    private struct Marker {
        var device: dev_t
        var inode: ino_t
    }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registered: [Int32: Marker] = [:]
    nonisolated(unsafe) private static var lettingGo = false

    /// Keeps `fd`, a marker just locked, as held by this process; let go at once while the host is away.
    static func register(_ fd: Int32) {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return }
        registryLock.lock()
        defer { registryLock.unlock() }
        registered[fd] = Marker(device: info.st_dev, inode: info.st_ino)
        if lettingGo { flock(fd, LOCK_UN) }
    }

    /// Closes a held marker's descriptor, out of the registry first (a later descriptor may reuse its
    /// number).
    static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        registryLock.lock()
        registered[fd] = nil
        registryLock.unlock()
        Darwin.close(fd)
    }

    /// Whether the marker open at `fd` is one this process holds, its lock let go or not.
    static func isRegistered(_ fd: Int32) -> Bool {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0 else { return false }
        registryLock.lock()
        defer { registryLock.unlock() }
        return registered.values.contains { $0.device == info.st_dev && $0.inode == info.st_ino }
    }

    static func letGo() {
        registryLock.lock()
        defer { registryLock.unlock() }
        lettingGo = true
        for fd in registered.keys { flock(fd, LOCK_UN) }
    }

    static func takeBack() {
        registryLock.lock()
        defer { registryLock.unlock() }
        lettingGo = false
        for fd in registered.keys where flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // Another process's sweep probing it this instant; still registered, so this process's
            // sweeps keep it, and the next return takes it.
            EngineLog.emit("[SessionDirectoryLiveness] live marker not taken back: errno=\(errno)", category: .session)
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
        // One of this process's own, its lock let go while the host is away (`letGo`).
        if isRegistered(fd) { return .held }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        return .held
    }

    /// Whether some open file description still holds `entry`'s marker. A missing marker answers
    /// false: it is a directory from a build without one, and the age check decides it as before.
    static func isLive(_ entry: URL) -> Bool { state(entry) == .held }
}
