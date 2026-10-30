import Testing
import Foundation
@testable import AetherEngine

/// The software host's tap sinks are written on the main actor (a tap installed, its stream stopped)
/// and read for every packet on the demux thread. Unguarded, a read racing a write could retain a
/// closure the write had just released and later call freed memory (ThreadSanitizer in reel's
/// sweep, 2026-10-30: `installSoftwareTapSink` against `startDemuxLoop`'s getter). The race shows
/// under `swift test --sanitize=thread`; a plain run sees at worst a crash.
@Suite("The software host's tap sinks are read and written under one lock")
struct SoftwareTapSinkRaceTests {

    final class Box: @unchecked Sendable {}

    @MainActor
    @Test("sinks swapped on the main actor while another thread reads them")
    func sinksSwappedWhileRead() async {
        let host = SoftwarePlaybackHost()
        let rounds = 20_000
        let reader = Task.detached {
            var seen = 0
            for _ in 0..<rounds {
                if host.audioTapSink != nil { seen += 1 }
                if host.subtitleTapSink != nil { seen += 1 }
            }
            return seen
        }
        for i in 0..<rounds {
            // A fresh closure holding a fresh object each time, so each write releases the last one's.
            let box = Box()
            host.audioTapSink = { _ in withExtendedLifetime(box) {} }
            if i % 2 == 0 {
                host.subtitleTapSink = { _, _, _, _ in withExtendedLifetime(box) {} }
            } else {
                host.subtitleTapSink = nil
            }
            if i % 500 == 0 { await Task.yield() }
        }
        host.audioTapSink = nil
        host.subtitleTapSink = nil
        _ = await reader.value
        #expect(host.audioTapSink == nil)
        #expect(host.subtitleTapSink == nil)
    }
}
