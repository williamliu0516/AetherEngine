import Foundation
import Testing
@testable import AetherEngine

/// W3147: a seek's restart is split into its steps for the host's report, and a custom source's restart reopen reads a
/// clone of the host's reader instead of failing on a URL FFmpeg has no protocol for.
@Suite("Seek restart phases", .serialized)
struct SeekRestartPhasesTests {

    @Test("each step is measured from the end of the one before, and a serve below the restart is not its own")
    func stepsFollowOneAnother() throws {
        let log = SeekRestartPhaseLog()
        let id = log.begin(segment: 30, now: 100)
        log.noteServed(index: 31, now: 100.5)   // before the keyframe: the old run's segment
        log.noteSteps(id, stop: 5.0, reopen: 3.1, reopenFailed: false, seek: 0.4, now: 108.5)
        log.noteKeyframe(id, now: 110.4)
        log.noteKeyframe(id, now: 111)          // only the first keyframe counts
        log.noteServed(index: 29, now: 110.5)   // the place the seek left
        log.noteServed(index: 30, now: 110.7)
        log.noteServed(index: 31, now: 112)

        let phases = log.snapshot
        #expect(phases.count == 1)
        let p = try #require(phases.first)
        #expect(p.began == 100)
        #expect(p.segment == 30)
        #expect(p.stop == 5.0)
        #expect(p.reopen == 3.1)
        #expect(p.seek == 0.4)
        #expect(abs((p.keyframe ?? 0) - 1.9) < 1e-9)
        #expect(abs((p.served ?? 0) - 0.3) < 1e-9)
    }

    @Test("only the last few restarts are kept, and a superseded restart's keyframe lands on its own entry")
    func boundedAndPerRestart() {
        let log = SeekRestartPhaseLog()
        let first = log.begin(segment: 1, now: 0)
        for i in 2...6 { _ = log.begin(segment: i, now: Double(i)) }
        log.noteKeyframe(first, now: 10)   // its entry is gone: nothing changes
        #expect(log.snapshot.map(\.segment) == [3, 4, 5, 6])
        #expect(log.snapshot.allSatisfy { $0.keyframe == nil })
    }

    /// Serves the fixture from memory; counts the readers the restart vends.
    private final class Vends: @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private var count = 0
        init(_ data: Data) { self.data = data }
        func vend() -> (reader: IOReader, formatHint: String?)? {
            lock.withLock { count += 1 }
            return (DataIOReader(data: data), "matroska")
        }
        var vended: Int { lock.withLock { count } }
    }

    @Test("a custom source's restart reopen opens a clone of its reader, and the restart's steps reach the log",
          .timeLimit(.minutes(1)))
    func customSourceReopenReadsAClone() async throws {
        let data = try #require(Data(base64Encoded: Issue234SideReaderSeekAnchorTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        // A host reader's URL is a name, not something FFmpeg can open (the app's range reader).
        let engine = HLSVideoEngine(url: try #require(URL(string: "zoolrange://w3147/fixture.mkv")),
                                    dvModeAvailable: false, preopenedDemuxer: demuxer,
                                    sourceReopenableByURL: false)
        let vends = Vends(data)
        engine.restartReopenReader = { vends.vend() }
        _ = try engine.start()
        defer { engine.stop() }
        let segments = try #require(engine.provider?.segmentCount)
        try #require(segments >= 3, "the fixture's plan has \(segments) segments")

        // The demuxer's last read threw (#169): the restart replaces it rather than seek the failed connection.
        engine.mainDemuxerSuspectDead = true
        engine.requestRestart(at: 2)

        #expect(vends.vended == 1)
        let phases = try #require(engine.seekPhaseLog.snapshot.last)
        #expect(phases.segment == 2)
        #expect(phases.reopen != nil)
        #expect(!phases.reopenFailed, "the reopen failed: the restart went on with the failed demuxer")
        try await waitFor { engine.seekPhaseLog.snapshot.last?.keyframe != nil }
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition())
    }
}
