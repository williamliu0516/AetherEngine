import Testing
import Foundation
@testable import AetherEngine

/// W3167 / W3168, design option E: a VOD session keeps its segment lead in memory up to the budget B
/// instead of writing every segment to disk, spills past B and under pressure, and never lets the
/// kernel empty a segment while it is served. Live always writes files (review H1).
@Suite("Segment memory cache", .serialized)
struct SegmentMemoryCacheTests {

    /// The budget's inputs, set by the test: available memory (nil = no per-process limit) and the clock.
    private final class Inputs: @unchecked Sendable {
        private let lock = NSLock()
        private var _available: Int?
        private var _now: Double = 1000
        var available: Int? {
            get { lock.lock(); defer { lock.unlock() }; return _available }
            set { lock.lock(); _available = newValue; lock.unlock() }
        }
        var now: Double {
            get { lock.lock(); defer { lock.unlock() }; return _now }
            set { lock.lock(); _now = newValue; lock.unlock() }
        }
    }

    private static let mib = 1 << 20

    private func makeCache(capBytes: Int, inputs: Inputs = Inputs(), retentionBytes: Int = 0,
                           live: LiveDVRRetentionPolicy? = nil) -> SegmentCache {
        let budget = SegmentMemoryBudget(availableMemory: { inputs.available }, capBytes: capBytes,
                                         hardFloorBytes: 0, now: { inputs.now })
        return SegmentCache(forwardWindow: 10, retentionBudgetBytes: retentionBytes,
                            baseDirectory: FileManager.default.temporaryDirectory
                                .appendingPathComponent("segmem tests 片-\(UUID().uuidString)", isDirectory: true),
                            nativeLiveDVRPolicy: live, memoryBudget: budget)
    }

    private func payload(_ index: Int, _ count: Int) -> Data {
        var data = Data(repeating: UInt8(truncatingIfNeeded: index), count: count)
        data[0] = 0xA5
        return data
    }

    /// Makes segment `index` as the producer does: into the buffer the cache hands out, else into a
    /// staging file the muxer reports as written; then adopts it. True when it went to memory.
    @discardableResult
    private func produce(_ cache: SegmentCache, _ index: Int, bytes: Int) throws -> Bool {
        let data = payload(index, bytes)
        if let buffer = cache.memorySegment(forIndex: index) {
            cache.beginInProgress(index: index, staged: .memory(buffer))
            let appended = data.withUnsafeBytes { buffer.append($0.baseAddress!, count: $0.count) }
            #expect(appended)
            cache.adopt(index: index, staged: .memory(buffer), byteCount: data.count)
            return true
        }
        let staging = cache.sessionDir.appendingPathComponent("staging-seg-\(index)-\(UUID().uuidString.prefix(8)).tmp")
        try data.write(to: staging)
        cache.noteBytesWrittenToDisk(data.count)
        cache.adopt(index: index, stagingPath: staging, byteCount: data.count)
        return false
    }

    private func segmentFiles(_ cache: SegmentCache) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.sessionDir.path)) ?? [])
            .filter { $0.hasPrefix("seg-") }
    }

    private func buffer(_ cache: SegmentCache, _ index: Int) -> SegmentMemoryBuffer? {
        if case .memory(let buffer)? = cache.storedSegment(index: index) { return buffer }
        return nil
    }

    // MARK: - Placement

    @Test("a lead within B stays in memory: no segment file, nothing written, every segment served")
    func placementUnderBudget() throws {
        let cache = makeCache(capBytes: 16 * Self.mib)
        defer { cache.close() }
        for i in 0..<20 { #expect(try produce(cache, i, bytes: 256 << 10)) }
        #expect(segmentFiles(cache).isEmpty)
        #expect(cache.bytesWrittenToDisk == 0)
        #expect(cache.storedDiskBytes == 0)
        #expect(cache.memoryBytes().counted == 20 * (256 << 10))
        for i in 0..<20 { #expect(cache.peek(index: i) == payload(i, 256 << 10)) }
        #expect(cache.residentIndexRanges() == [0...19])
    }

    @Test("past B the segments go to files, counted as written")
    func spillPastBudget() throws {
        let cache = makeCache(capBytes: 10 * Self.mib)
        defer { cache.close() }
        var inMemory = 0
        for i in 0..<16 {
            if try produce(cache, i, bytes: Self.mib) { inMemory += 1 }
        }
        #expect(inMemory == 10)
        #expect(segmentFiles(cache).count == 6)
        #expect(cache.bytesWrittenToDisk == 6 * Self.mib)
        #expect(cache.memoryBytes().counted <= 10 * Self.mib)
        for i in 0..<16 { #expect(cache.peek(index: i) == payload(i, Self.mib)) }
    }

    // MARK: - Behind the target

    @Test("a purged segment behind the target is not resident, and the producer makes it again")
    func purgedBehindSegmentRefetched() throws {
        let cache = makeCache(capBytes: 64 * Self.mib, retentionBytes: 64 * Self.mib)
        defer { cache.close() }
        let size = 64 << 10
        for i in 0..<40 { try produce(cache, i, bytes: size) }
        cache.declareTarget(30)
        // The handover cushion (memoryKeepBehind below the target) and the lead stay counted.
        let memory = cache.memoryBytes()
        #expect(memory.counted == 20 * size)
        #expect(memory.volatile == 20 * size)

        let behind = try #require(buffer(cache, 5))
        #expect(behind.isVolatile)
        behind.purgeForTesting()

        // M2: the walks never count it, so a back-seek there is not kept on a purged band.
        #expect(cache.residentIndexRanges() == [0...4, 6...39])
        #expect(cache.contiguousBackwardFloor(from: 12) == 6)
        #expect(!cache.isStored(index: 5))
        #expect(cache.peek(index: 5) == nil)
        #expect(cache.purgedSegments == 1)

        try produce(cache, 5, bytes: size)
        #expect(cache.isStored(index: 5))
        #expect(cache.peek(index: 5) == payload(5, size))
    }

    /// Reads segment `index` the way a serve does and checks it while it is held.
    private func serve(_ cache: SegmentCache, _ index: Int, size: Int, whileHeld: () -> Void) {
        guard let data = cache.peek(index: index) else {
            Issue.record("a volatile segment the kernel kept is served"); return
        }
        whileHeld()
        #expect(data == payload(index, size))
    }

    @Test("a volatile segment pinned by a serve stays non-volatile until the serve lets go")
    func pinnedWhileServed() throws {
        let cache = makeCache(capBytes: 64 * Self.mib, retentionBytes: 64 * Self.mib)
        defer { cache.close() }
        let size = 64 << 10
        for i in 0..<40 { try produce(cache, i, bytes: size) }
        cache.declareTarget(30)
        let behind = try #require(buffer(cache, 5))
        #expect(behind.isVolatile)

        serve(cache, 5, size: size) {
            #expect(!behind.isVolatile)
            #expect(behind.pinCount == 1)
            // The target moves on while the bytes are out: the cache wants it volatile again, the pin
            // keeps it counted.
            cache.declareTarget(31)
            #expect(!behind.isVolatile)
        }
        #expect(behind.pinCount == 0)
        #expect(behind.isVolatile)
    }

    // MARK: - Live

    @Test("live never goes to memory: a rewind behind the edge finds its files (H1)")
    func liveRewindKept() throws {
        let policy = LiveDVRRetentionPolicy(now: { 0 })
        policy.update(.init(windowSeconds: 600, maximumBytes: 64 << 20, minimumFreeBytes: 0,
                            capacityValidUntil: 1e9),
                      availableBytes: 1 << 30, residentBytes: 0)
        let cache = makeCache(capBytes: 64 * Self.mib, live: policy)
        defer { cache.close() }
        let size = 64 << 10
        for i in 0..<120 {
            #expect(!(try produce(cache, i, bytes: size)))
            cache.declareTarget(i)
        }
        let memory = cache.memoryBytes()
        #expect(memory.counted == 0 && memory.volatile == 0)
        // 100 segments behind the edge, past every memory band: still a file, still served.
        #expect(cache.fileURLIfOnDisk(index: 19) != nil)
        #expect(cache.peek(index: 19) == payload(19, size))
    }

    // MARK: - Pressure

    @Test("a memory-pressure event spills the farthest-ahead segments down to B / 2 and holds new ones")
    func pressureShrinks() throws {
        let inputs = Inputs()
        let cache = makeCache(capBytes: 10 * Self.mib, inputs: inputs)
        defer { cache.close() }
        for i in 0..<10 { #expect(try produce(cache, i, bytes: Self.mib)) }

        cache.noteMemoryPressure()
        cache.drainSpillsForTesting()
        #expect(cache.spilledSegments == 5)
        #expect(cache.memoryBytes().counted == 5 * Self.mib)
        #expect(cache.fileURLIfOnDisk(index: 9) != nil)
        #expect(cache.fileURLIfOnDisk(index: 0) == nil)
        #expect(cache.bytesWrittenToDisk == 5 * Self.mib)
        for i in 0..<10 { #expect(cache.peek(index: i) == payload(i, Self.mib)) }

        // Held back for the pressure window, then admitted again.
        #expect(cache.memorySegment(forIndex: 10) == nil)
        inputs.now += 61
        #expect(cache.memorySegment(forIndex: 10) != nil)
    }

    @Test("when the process's available memory falls, the cache shrinks to the new B (H3)")
    func availableMemoryShrinks() throws {
        let inputs = Inputs()
        inputs.available = 60 * Self.mib
        let cache = makeCache(capBytes: 64 * Self.mib, inputs: inputs)
        defer { cache.close() }
        for i in 0..<6 { #expect(try produce(cache, i, bytes: Self.mib)) }

        inputs.available = 3 * Self.mib
        #expect(cache.memorySegment(forIndex: 6) == nil)
        cache.drainSpillsForTesting()
        #expect(cache.memoryBytes().counted <= 3 * Self.mib)
        #expect(cache.spilledSegments >= 3)
        for i in 0..<6 { #expect(cache.peek(index: i) == payload(i, Self.mib)) }
    }

    // MARK: - Progressive reads of a memory segment (M7)

    @Test("a progressive reader follows a memory segment as another thread writes it, to the seal")
    func progressiveReaderOverGrowingBuffer() throws {
        let cache = makeCache(capBytes: 64 * Self.mib)
        defer { cache.close() }
        let buffer = try #require(cache.memorySegment(forIndex: 0))
        cache.beginInProgress(index: 0, staged: .memory(buffer))
        guard case .progressive(let reader) = cache.fetchSource(index: 0, timeout: 1, progressive: true) else {
            Issue.record("a memory segment being written is served by a reader"); return
        }
        // Enough to make the buffer grow past its first region (sized from an 8 MiB guess) while it is read.
        let chunks = (0..<160).map { Data(repeating: UInt8($0), count: 96 << 10) }
        var whole = Data()
        for chunk in chunks { whole.append(chunk) }
        let writer = DispatchQueue(label: "segmem-writer")
        writer.async {
            for chunk in chunks {
                chunk.withUnsafeBytes { _ = buffer.append($0.baseAddress!, count: $0.count) }
            }
            cache.adopt(index: 0, staged: .memory(buffer), byteCount: whole.count)
        }
        #expect(reader.readToEnd() == whole)
        writer.sync {}
    }

    @Test("a reader of an abandoned memory segment reads as abandoned")
    func progressiveReaderAbandoned() throws {
        let cache = makeCache(capBytes: 64 * Self.mib)
        defer { cache.close() }
        let buffer = try #require(cache.memorySegment(forIndex: 2))
        cache.beginInProgress(index: 2, staged: .memory(buffer))
        let part = Data(repeating: 7, count: 1000)
        part.withUnsafeBytes { _ = buffer.append($0.baseAddress!, count: $0.count) }
        guard case .progressive(let reader) = cache.fetchSource(index: 2, timeout: 1, progressive: true) else {
            Issue.record("a memory segment being written is served by a reader"); return
        }
        #expect(reader.next() == .bytes(part))
        cache.abandonInProgress(index: 2)
        #expect(reader.next() == .abandoned)
    }

    // MARK: - In-progress memory (W3169)

    @Test("a segment being written into memory counts against B though nobody serves it progressively")
    func unservedSegmentBeingWrittenCounts() throws {
        let cache = makeCache(capBytes: 16 * Self.mib)
        defer { cache.close() }
        #expect(try produce(cache, 0, bytes: Self.mib))
        do {
            // The producer writes segment 1 with progressive serving off: no `beginInProgress`.
            let writing = try #require(cache.memorySegment(forIndex: 1))
            let part = Data(repeating: 1, count: 15 * Self.mib)
            #expect(part.withUnsafeBytes { writing.append($0.baseAddress!, count: $0.count) })
            #expect(cache.memoryBytes().counted == 16 * Self.mib)
            #expect(cache.memorySegment(forIndex: 2) == nil,
                    "16 MiB counted plus the last segment's 1 MiB does not fit a 16 MiB B")
            withExtendedLifetime(writing) {}
        }
        // A restart dropped the unadopted buffer: it no longer counts.
        #expect(cache.memoryBytes().counted == Self.mib)
    }

    // MARK: - Serving (review L1)

    private func makeProvider(_ cache: SegmentCache) -> VideoSegmentProvider {
        let segments = (0..<6).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        return VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: false)
    }

    @Test("a memory segment served the way the server asks counts one request and declares one target")
    func memoryServeCountsOnce() throws {
        let cache = makeCache(capBytes: 64 * Self.mib)
        defer { cache.close() }
        let provider = makeProvider(cache)
        for i in 0..<3 { #expect(try produce(cache, i, bytes: 64 << 10)) }
        // HLSLocalServer: the sendfile fast path first, then the data path on its nil.
        #expect(provider.mediaSegmentURL(at: 2) == nil)
        guard case .data(let served)? = provider.mediaSegmentSource(at: 2, onSlow: nil) else {
            Issue.record("a memory segment is served as data"); return
        }
        #expect(served == payload(2, 64 << 10))
        #expect(provider.mediaFetchCount == 1)
        #expect(cache.targetIndex == 2)

        // A file segment is answered by the fast path alone, and counted there once.
        cache.store(index: 3, data: payload(3, 1000))
        #expect(provider.mediaSegmentURL(at: 3) != nil)
        #expect(provider.mediaFetchCount == 2)
    }

    // MARK: - Scrub thumbnails (review M5)

    private func thumbnailSource(_ provider: VideoSegmentProvider, atSeconds seconds: Double,
                                 initData: Data) -> HLSVideoEngine.ScrubThumbnailSource? {
        guard let seg = provider.thumbnailSegment(atSeconds: seconds),
              let identity = HLSVideoEngine.scrubThumbnailIdentity(index: seg.index, stored: seg.stored,
                                                                   initData: initData) else { return nil }
        return HLSVideoEngine.ScrubThumbnailSource(
            segmentIndex: seg.index, startSeconds: seg.startSeconds, durationSeconds: seg.durationSeconds,
            carriedOffset: 0, identity: identity, initData: initData, segment: seg.stored)
    }

    @Test("a scrub over a memory segment decodes from its bytes: no file written, one identity until it is made again")
    func scrubThumbnailFromMemory() throws {
        let cache = makeCache(capBytes: 64 * Self.mib)
        defer { cache.close() }
        let provider = makeProvider(cache)
        for i in 0..<4 { #expect(try produce(cache, i, bytes: 64 << 10)) }
        let written = cache.bytesWrittenToDisk
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: cache.sessionDir.path).sorted()
        let initData = Data([1, 2, 3, 4])

        let source = try #require(thumbnailSource(provider, atSeconds: 9, initData: initData),
                                  "a scrub over the memory lead finds its segment")
        #expect(source.segmentIndex == 2)
        let reader = try #require(source.makeReader())
        var read = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 8192) }
            if n <= 0 { break }
            read.append(contentsOf: chunk[0..<Int(n)])
        }
        #expect(read == initData + payload(2, 64 << 10))
        let again = try #require(thumbnailSource(provider, atSeconds: 10, initData: initData))
        #expect(again.identity == source.identity, "a second sample of the same segment is an extractor hit")
        #expect(cache.bytesWrittenToDisk == written)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.sessionDir.path).sorted() == filesBefore)

        // The same index made again (a restart's re-cut) is other bytes, so another extractor.
        #expect(try produce(cache, 2, bytes: 64 << 10))
        let remade = try #require(thumbnailSource(provider, atSeconds: 9, initData: initData))
        #expect(remade.identity != source.identity)
    }
}
