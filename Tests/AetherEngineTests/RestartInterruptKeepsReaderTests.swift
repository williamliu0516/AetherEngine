import Foundation
import Testing
@testable import AetherEngine

/// W3153: a restart's read interrupt (`CustomIOReaderBridge.interruptRead`, W3146) ends the read in flight only. The
/// engine's own readers have a terminal `cancel()`; the interrupt used to reach them through it, so an HEVC-in-TS HLS
/// VOD (`HLSVODIngestReader`) could not seek again after one interrupted restart, and a disc read through
/// `HTTPDiscIOReader` failed every read after one.
@Suite("A restart's read interrupt keeps the engine's reader usable", .serialized)
struct RestartInterruptKeepsReaderTests {

    /// A read run off the test's thread, as the demuxer's pump runs it.
    private final class PendingRead: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Int32?
        private(set) var bytes = [UInt8](repeating: 0, count: 64)

        init(_ bridge: CustomIOReaderBridge) {
            Thread.detachNewThread { [self] in
                var local = [UInt8](repeating: 0, count: 64)
                let n = local.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 64) }
                lock.withLock { bytes = local; result = n }
            }
        }

        var value: Int32? { lock.withLock { result } }
        var first: UInt8 { lock.withLock { bytes[0] } }
    }

    /// Interrupts until the parked read returns, as `stopForRestart` asks again when the first ask found the read
    /// not yet parked; then ends the interrupt, as the restart does once the old pump has exited.
    private func interruptUntilReturned(_ bridge: CustomIOReaderBridge, _ read: PendingRead) async throws -> Int32 {
        while true {
            bridge.interruptRead()
            // test-wait: the bound is the restart's own re-ask interval, not an assertion.
            if try await waitFor(upTo: .milliseconds(200), { read.value != nil }) { break }
        }
        bridge.endReadInterrupt()
        return try #require(read.value)
    }

    @Test("an interrupted HLS VOD ingest read leaves the reader seekable and reading", .timeLimit(.minutes(1)))
    func hlsVODIngestReadsOnAfterAnInterrupt() async throws {
        HeldURLProtocol.reset(heldSuffix: ".ts")
        defer { HeldURLProtocol.reset(heldSuffix: nil) }
        let base = "https://vod.test/w3153/"
        HeldURLProtocol.set(base + "media.m3u8", Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6,
            seg0.ts
            #EXTINF:6,
            seg1.ts
            #EXTINF:6,
            seg2.ts
            #EXT-X-ENDLIST
            """.utf8))
        for index in 0..<3 {
            HeldURLProtocol.set(base + "seg\(index).ts", Data(repeating: UInt8(index + 1), count: 188 * 2))
        }
        let session = HeldURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let reader = HLSVODIngestReader(playlistURL: try #require(URL(string: base + "media.m3u8")),
                                        httpHeaders: [:], session: session)
        defer { reader.close() }
        let bridge = CustomIOReaderBridge(reader: reader)

        // The pump's read parks waiting for a segment that has not arrived.
        let parked = PendingRead(bridge)
        try await waitFor { HeldURLProtocol.heldRequests > 0 }
        #expect(try await interruptUntilReturned(bridge, parked) == -1)

        // The restart repositions the reused demuxer's reader and reads on.
        #expect(reader.seek(to: 12), "the interrupt left the ingest unable to seek")
        HeldURLProtocol.release()
        let next = PendingRead(bridge)
        try await waitFor { next.value != nil }
        #expect(next.value == 64, "the read after the restart got \(String(describing: next.value))")
        #expect(next.first == 2, "12 s restarts one segment ahead, at seg1")
    }

    @Test("an interrupted HTTP disc read leaves the reader reading", .timeLimit(.minutes(1)))
    func httpDiscReadsOnAfterAnInterrupt() async throws {
        HeldURLProtocol.reset(heldSuffix: nil)
        defer { HeldURLProtocol.reset(heldSuffix: nil) }
        let url = try #require(URL(string: "http://disc.test/w3153/disc.iso"))
        let source = Data((0..<4096).map { UInt8($0 % 251) })
        HeldURLProtocol.set(url.absoluteString, source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldURLProtocol.self]
        let reader = try #require(HTTPDiscIOReader(url: url, baseChunkSize: 1024, maxChunkSize: 1024,
                                                   requestTimeout: 30, sessionConfiguration: configuration))
        defer { reader.close() }
        let bridge = CustomIOReaderBridge(reader: reader)

        // Past the size probe: every range request now waits, as on a slow origin.
        HeldURLProtocol.hold(suffix: ".iso")
        let parked = PendingRead(bridge)
        try await waitFor { HeldURLProtocol.heldRequests > 0 }
        #expect(try await interruptUntilReturned(bridge, parked) == -1)

        HeldURLProtocol.release()
        let next = PendingRead(bridge)
        try await waitFor { next.value != nil }
        #expect(next.value == 64, "the read after the restart got \(String(describing: next.value))")
        #expect(next.bytes == [UInt8](source.prefix(64)))
    }
}

/// Serves fixed bodies (byte ranges included) and, while holding, leaves requests whose URL ends in the held suffix
/// unanswered until `release()` or until the client cancels them.
final class HeldURLProtocol: URLProtocol, @unchecked Sendable {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var heldSuffix: String?
    nonisolated(unsafe) private static var held = 0
    private var stopped = false

    static func reset(heldSuffix suffix: String?) {
        condition.withLock {
            bodies = [:]
            heldSuffix = suffix
            held = 0
            condition.broadcast()
        }
    }

    static func set(_ url: String, _ body: Data) { condition.withLock { bodies[url] = body } }
    static func hold(suffix: String) { condition.withLock { heldSuffix = suffix } }
    static func release() { condition.withLock { heldSuffix = nil; condition.broadcast() } }
    static var heldRequests: Int { condition.withLock { held } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        Self.condition.withLock {
            stopped = true
            Self.condition.broadcast()
        }
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let isHeld = Self.condition.withLock { () -> Bool in
            guard let suffix = Self.heldSuffix, url.hasSuffix(suffix) else { return false }
            Self.held += 1
            return true
        }
        guard isHeld else { answer(url); return }
        Thread.detachNewThread { [self] in
            Self.condition.lock()
            while let suffix = Self.heldSuffix, url.hasSuffix(suffix), !stopped { Self.condition.wait() }
            let cancelled = stopped
            Self.condition.unlock()
            if !cancelled { answer(url) }
        }
    }

    private func answer(_ url: String) {
        guard let requestURL = request.url, let body = Self.condition.withLock({ Self.bodies[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var status = 200
        var slice = body
        var headers = ["Content-Length": String(body.count)]
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let start = bounds.first ?? 0
            let end = min(bounds.count > 1 ? bounds[1] : body.count - 1, body.count - 1)
            slice = body.subdata(in: start..<(end + 1))
            status = 206
            headers = ["Content-Length": String(slice.count), "Content-Range": "bytes \(start)-\(end)/\(body.count)"]
        }
        let response = HTTPURLResponse(url: requestURL, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
}
