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
        return fd
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
