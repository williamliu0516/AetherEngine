import Foundation
#if canImport(os)
import os
#endif

/// How much of a VOD session's segment lead the cache may hold in memory instead of writing it to
/// disk (W3167, design option E, with the W3149 review's H3, M1 and L4 folded in).
///
/// B = clamp((available + the cache's own counted memory) / 3, min(160 MB, available / 4), cap).
/// Available memory is `os_proc_available_memory()`, which tracks this process's own jetsam limit;
/// the cache's own bytes are added back so B does not shrink itself as it fills. The cap is 1 GiB,
/// and on the Mac, where there is no per-process limit to read, min(1 GiB, physical memory / 8).
///
/// Re-read at each segment open, each target change, and every `refreshSeconds` while the cache holds
/// memory (W3171 L2: a paused session opens nothing). Below `hardFloorBytes` of available memory,
/// or within `pressureHoldSeconds` of a memory-pressure event, nothing new goes to memory and what is
/// held is spilled down to B / 2.
struct SegmentMemoryBudget: Sendable {
    /// This process's available memory in bytes; nil, or 0 as `os_proc_available_memory` answers
    /// where the process has no limit (W3171 L1), means no per-process limit: B is the cap.
    var availableMemory: @Sendable () -> Int?
    var capBytes: Int
    var floorBytes: Int = 160 << 20
    var hardFloorBytes: Int = 256 << 20
    var pressureHoldSeconds: Double = 60
    var refreshSeconds: Double = 2
    var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }

    static var system: SegmentMemoryBudget {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        return SegmentMemoryBudget(availableMemory: { nil }, capBytes: min(1 << 30, physical / 8))
        #else
        return SegmentMemoryBudget(availableMemory: { Int(os_proc_available_memory()) }, capBytes: 1 << 30)
        #endif
    }

    /// B for a cache already holding `heldBytes` of counted memory.
    func bytes(heldBytes: Int) -> Int {
        guard let available = processLimitAvailable() else { return capBytes }
        let floor = min(floorBytes, available / 4)
        return min(capBytes, max(floor, (available + heldBytes) / 3))
    }

    /// Whether available memory is below the hard floor: nothing new to memory, shrink to B / 2.
    var isCritical: Bool {
        guard let available = processLimitAvailable() else { return false }
        return available < hardFloorBytes
    }

    /// Available memory under a per-process limit, or nil when there is none (nil or 0).
    private func processLimitAvailable() -> Int? {
        guard let available = availableMemory(), available > 0 else { return nil }
        return available
    }
}
