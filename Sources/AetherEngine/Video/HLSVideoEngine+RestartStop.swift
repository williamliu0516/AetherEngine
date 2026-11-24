import Foundation

extension HLSVideoEngine {
    /// How long a stopped pump gets to leave on its own before its read is interrupted.
    static let restartStopGraceSeconds: TimeInterval = 0.1

    /// W3146: stop `old` for a restart and wait at most `timeout` for its pump to leave. A pump still
    /// inside a read after the grace is parked on the network (a cloud drive's read waits for bytes
    /// that the seek no longer wants), and `stop()` alone cannot end that read: the restart waited out
    /// the whole timeout, 5 s, before the #79 fallback. Its read on each of `demuxers` is interrupted
    /// instead (`Demuxer.interruptRead`), which leaves them usable for the producer the restart builds
    /// next. Asked twice, because a read just entering the host's reader can miss the first cancel.
    /// Returns whether the pump exited.
    static func stopForRestart(_ old: HLSSegmentProducer, demuxers: [Demuxer], interrupting: Bool,
                                           timeout: TimeInterval) -> Bool {
        old.stop()
        if old.waitForFinish(timeout: min(timeout, restartStopGraceSeconds)) { return true }
        guard interrupting else { return old.waitForFinish(timeout: max(0, timeout - restartStopGraceSeconds)) }
        for demuxer in demuxers { demuxer.interruptRead() }
        let secondAsk = restartStopGraceSeconds * 4
        var exited = old.waitForFinish(timeout: secondAsk)
        if !exited {
            for demuxer in demuxers { demuxer.interruptRead() }
            exited = old.waitForFinish(timeout: max(0, timeout - restartStopGraceSeconds - secondAsk))
        }
        for demuxer in demuxers { demuxer.endReadInterrupt(clearingReadError: exited) }
        return exited
    }
}
