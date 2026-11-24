import Foundation
import Testing
@testable import AetherEngine

/// W3154: a restart's reopen of a custom source opens on the host's replacement reader (which keeps the main reader's
/// gate and diagnostics), and a disc image reopens the title the session plays from the recognition the load kept.
@Suite("A restart's reopen source")
struct RestartReopenSourceTests {

    /// A host reader whose main reader carries more than its independent clones (the app's PlayAhead gate).
    private final class GatedHostReader: IOReader, @unchecked Sendable {
        let independent = DataIOReader(data: Data(count: 16))
        let replacement = DataIOReader(data: Data(count: 16))
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { 0 }
        func close() {}
        func makeIndependentReader() -> IOReader? { independent }
        func makeReplacementReader() -> IOReader? { replacement }
    }

    /// A host reader that only clones.
    private final class CloningHostReader: IOReader, @unchecked Sendable {
        let independent = DataIOReader(data: Data(count: 16))
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { 0 }
        func close() {}
        func makeIndependentReader() -> IOReader? { independent }
    }

    @Test("the reopen reads through the host's replacement reader, and a clone where the host names none")
    func reopenUsesTheReplacementReader() throws {
        let gated = GatedHostReader()
        let vend = RestartReopenSource.vendor(gated, formatHint: "matroska", discTitleID: 3, discCacheKey: "k")
        let source = try #require(vend())
        #expect(source.reader === gated.replacement, "the reopen read through an ungated clone")
        #expect(source.formatHint == "matroska")
        #expect(source.discTitleID == 3)
        #expect(source.discCacheKey == "k")

        let cloning = CloningHostReader()
        let plain = try #require(RestartReopenSource.vendor(cloning, formatHint: nil, discTitleID: nil,
                                                            discCacheKey: nil)())
        #expect(plain.reader === cloning.independent)
    }

    /// Records the lowest offset any read starts at.
    private final class OffsetRecordingReader: IOReader, @unchecked Sendable {
        private let base: DataIOReader
        private let lock = NSLock()
        private var position: Int64 = 0
        private var lowest = Int64.max
        init(_ data: Data) { base = DataIOReader(data: data) }
        var lowestRead: Int64 { lock.withLock { lowest } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            lock.withLock { lowest = min(lowest, position) }
            let n = base.read(buffer, size: size)
            if n > 0 { lock.withLock { position += Int64(n) } }
            return n
        }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            let p = base.seek(offset: offset, whence: whence)
            if p >= 0, whence != 65536 { lock.withLock { position = p } }
            return p
        }
        func close() { base.close() }
    }

    /// Minimal single-title Blu-ray UDF image (one .mpls, one m2ts clip), as `DiscRecognitionCacheTests` builds it.
    private func bdImage() -> (image: Data, payload: [UInt8]) {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        return (UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts), Array(m2ts.prefix(16)))
    }

    @Test("a disc image's reopen plays the session's title from the recognition kept at load, reading no directory")
    func discReopenKeepsTitleAndRecognition() throws {
        let (image, payload) = bdImage()
        let payloadStart = try #require(image.range(of: Data(payload))?.lowerBound)
        let key = "zoolrange://w3154/\(UUID().uuidString)/disc.iso"
        // The load (or a reload) recognised the disc under the session's key.
        _ = try #require(try DiscReader.wrap(DataIOReader(data: image), selectTitleID: nil, cacheKey: key))

        let reader = OffsetRecordingReader(image)
        let source = RestartReopenSource(reader: reader, formatHint: nil, discTitleID: 0, discCacheKey: key)
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // The fixture's clip is filler: whether FFmpeg opens it is not this test's question.
        try? source.open(demuxer, profile: .restartReopen)

        #expect(demuxer.selectedDiscTitleID == 0, "the reopen did not open the session's disc title")
        #expect(reader.lowestRead >= Int64(payloadStart),
                "the reopen parsed the disc again (read at \(reader.lowestRead), clip at \(payloadStart))")
    }
}
