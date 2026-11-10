import XCTest
@testable import AetherEngine
@testable import AetherEngineSMB

private final class FakeByteRangeSource: ByteRangeSource, @unchecked Sendable {
    let data: Data
    private(set) var closeCount = 0
    private(set) var requests: [Int] = []
    private(set) var probeReads = 0
    let maximumProbeReadAttempts: Int?
    init(_ data: Data, attempts: Int? = 1) {
        self.data = data
        maximumProbeReadAttempts = attempts
    }
    var byteSize: Int64 { Int64(data.count) }
    func read(at offset: Int64, length: Int) async throws -> Data {
        // Exercise the declared worst case: each retry asks for the same range before one answers.
        for _ in 0..<max(1, maximumProbeReadAttempts ?? 1) { requests.append(length) }
        guard offset >= 0, offset < data.count, length > 0 else { return Data() }
        let end = min(Int(offset) + length, data.count)
        return data.subdata(in: Int(offset)..<end)
    }
    func readForProbe(at offset: Int64, length: Int) async throws -> Data {
        probeReads += 1
        return try await read(at: offset, length: length)
    }
    func close() { closeCount += 1 }
}

/// Stops after ProbeIOReader's allowance check, before the disposable reader starts I/O.
private final class BeforeReadGate: IOReader, @unchecked Sendable {
    let proceed = DispatchSemaphore(value: 0)
    private let reader: IOReader
    private let entered: @Sendable () -> Void
    init(reader: IOReader, entered: @escaping @Sendable () -> Void) {
        self.reader = reader
        self.entered = entered
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        entered()
        proceed.wait()
        return reader.read(buffer, size: size)
    }
    func seek(offset: Int64, whence: Int32) -> Int64 { reader.seek(offset: offset, whence: whence) }
    func cancel() { reader.cancel() }
    func close() {}
}

private func readN(_ r: SMBIOReader, _ n: Int) -> Data {
    var buf = [UInt8](repeating: 0, count: n)
    let got = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: Int32(n)) }
    return Data(buf.prefix(Int(max(got, 0))))
}

final class SMBIOReaderTests: XCTestCase {
    private let payload = Data((0..<256).map { UInt8($0) })

    func testSequentialReadAdvancesCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(readN(r, 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(readN(r, 4), Data([4, 5, 6, 7]))
    }

    func testSeekSetThenRead() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(readN(r, 2), Data([10, 11]))
    }

    func testSeekCurAndEnd() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        _ = readN(r, 4)
        XCTAssertEqual(r.seek(offset: 4, whence: SEEK_CUR), 8)
        XCTAssertEqual(r.seek(offset: -1, whence: SEEK_END), 255)
        XCTAssertEqual(readN(r, 1), Data([255]))
    }

    func testAvseekSizeReturnsTotalWithoutMovingCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 8, whence: SEEK_SET), 8)
        XCTAssertEqual(r.seek(offset: 0, whence: 65536), 256) // AVSEEK_SIZE
        XCTAssertEqual(readN(r, 1), Data([8]))               // cursor unmoved
    }

    func testReadAtEofReturnsZero() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 256, whence: SEEK_SET), 256)
        var buf = [UInt8](repeating: 0, count: 16)
        let got = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 16) }
        XCTAssertEqual(got, 0)
    }

    func testReadSpanningEofTruncates() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 254, whence: SEEK_SET), 254)
        XCTAssertEqual(readN(r, 16), Data([254, 255]))
    }

    func testInvalidWhenceReturnsNegative() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertLessThan(r.seek(offset: 0, whence: 999), 0)
    }

    func testOwnedSourceClosesOnceIndependentDoesNot() {
        let src = FakeByteRangeSource(payload)
        let primary = SMBIOReader(source: src, ownsSource: true)
        let secondary = primary.makeIndependentReader()
        secondary?.close()
        XCTAssertEqual(src.closeCount, 0) // independent reader must not close shared source
        primary.close()
        primary.close()                   // idempotent
        XCTAssertEqual(src.closeCount, 1)
    }

    func testDiscImageProbeDefaultsOnAndIndependentReaderPreservesOptOut() throws {
        let defaultReader = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertTrue(defaultReader.discImageProbeEnabled)

        let ordinaryMediaReader = SMBIOReader(
            source: FakeByteRangeSource(payload),
            discImageProbeEnabled: false
        )
        XCTAssertFalse(ordinaryMediaReader.discImageProbeEnabled)
        let independent = try XCTUnwrap(ordinaryMediaReader.makeIndependentReader())
        XCTAssertFalse(independent.discImageProbeEnabled)
    }

    func testBoundedIndependentReaderCountsSparseRequestsAndLeavesPlaybackAlone() throws {
        let source = FakeByteRangeSource(payload)
        let primary = SMBIOReader(source: source, discImageProbeEnabled: false)
        let probe = try XCTUnwrap(primary.makeIndependentReader(limits: ProbeLimits(maxInputBytes: 6)) as? SMBIOReader)
        defer { probe.close(); primary.close() }
        XCTAssertFalse(probe.discImageProbeEnabled)
        XCTAssertEqual(readN(probe, 4), Data([0, 1, 2, 3]))
        XCTAssertEqual(probe.seek(offset: 100, whence: SEEK_SET), 100)
        XCTAssertEqual(readN(probe, 4), Data([100, 101]))
        XCTAssertEqual(readN(probe, 1), Data())
        XCTAssertEqual(source.requests, [4, 2])
        XCTAssertEqual(source.probeReads, 2)
        probe.close()
        XCTAssertEqual(source.closeCount, 0)
        XCTAssertEqual(readN(primary, 2), Data([0, 1]))
    }

    func testBoundedIndependentReaderReservesInternalRetriesToo() throws {
        let source = FakeByteRangeSource(payload, attempts: 3)
        let primary = SMBIOReader(source: source)
        let probe = try XCTUnwrap(primary.makeIndependentReader(limits: ProbeLimits(maxInputBytes: 10)) as? SMBIOReader)
        defer { probe.close(); primary.close() }
        XCTAssertEqual(readN(probe, 4), Data([0, 1, 2]))
        XCTAssertEqual(probe.seek(offset: 100, whence: SEEK_SET), 100)
        XCTAssertEqual(readN(probe, 1), Data())
        XCTAssertEqual(source.requests, [3, 3, 3])
        XCTAssertLessThanOrEqual(source.requests.reduce(0, +), 10)
    }

    func testBoundedIndependentReaderSkipsSourcesWithoutARequestBound() {
        let bounds: [Int?] = [nil, 0, -1]
        for attempts in bounds {
            let source = FakeByteRangeSource(payload, attempts: attempts)
            let primary = SMBIOReader(source: source)
            defer { primary.close() }
            XCTAssertNil(primary.makeIndependentReader(limits: ProbeLimits()))
            XCTAssertTrue(source.requests.isEmpty)
            XCTAssertNotNil(primary.makeIndependentReader())
        }
    }

    func testBoundedIndependentReaderCannotReadAfterCancelOrClose() throws {
        let source = FakeByteRangeSource(payload)
        let primary = SMBIOReader(source: source)
        defer { primary.close() }
        for close in [false, true] {
            let probe = try XCTUnwrap(primary.makeIndependentReader(limits: ProbeLimits()) as? SMBIOReader)
            if close { probe.close() } else { probe.cancel() }
            XCTAssertEqual(readN(probe, 1), Data())
            probe.close()
        }
        XCTAssertTrue(source.requests.isEmpty)
        XCTAssertEqual(source.closeCount, 0)
        // Ordinary independent readers retain their reusable cancellation semantics.
        let ordinary = try XCTUnwrap(primary.makeIndependentReader() as? SMBIOReader)
        defer { ordinary.close() }
        ordinary.cancel()
        XCTAssertEqual(readN(ordinary, 1), Data([0]))
    }

    func testBoundedCancelBetweenAllowanceAndUnderlyingReadStartsNoRequest() async throws {
        let source = FakeByteRangeSource(payload)
        let primary = SMBIOReader(source: source)
        let probe = try XCTUnwrap(primary.makeIndependentReader(limits: ProbeLimits()))
        let entered = expectation(description: "allowance passed, delegate read not started")
        let ended = expectation(description: "cancelled read returned")
        let gate = BeforeReadGate(reader: probe, entered: { entered.fulfill() })
        let cancellation = ProbeCancellation()
        let control = try ProbeControl(limits: nil, cancellation: cancellation)
        let counted = ProbeIOReader(reader: gate, control: control)
        defer { gate.proceed.signal(); control.finish(); probe.close(); primary.close() }
        Thread.detachNewThread {
            var byte: UInt8 = 0
            _ = counted.read(&byte, size: 1)
            ended.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        cancellation.cancel()
        gate.proceed.signal()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertTrue(source.requests.isEmpty)
        XCTAssertEqual(source.closeCount, 0)
        XCTAssertEqual(readN(primary, 1), Data([0]))
    }

    func testNegativeSeekDoesNotCorruptCursor() {
        let r = SMBIOReader(source: FakeByteRangeSource(payload))
        XCTAssertEqual(r.seek(offset: 10, whence: SEEK_SET), 10)
        XCTAssertEqual(readN(r, 2), Data([10, 11]))
        XCTAssertLessThan(r.seek(offset: -999, whence: SEEK_SET), 0)
        // Cursor must be unchanged: next read should still start at 12.
        XCTAssertEqual(readN(r, 2), Data([12, 13]))
    }
}
