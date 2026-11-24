import Testing
import Foundation
@testable import AetherEngine

/// W3154: a restart's read interrupt (`AVIOReader.interruptRead`, W3146) ends a URL source's read waiting on the
/// forward-only streaming path at once, where its semaphore wait used to run its full 15 s, and the stream is kept:
/// the next read goes on with the bytes that follow.
@Suite("AVIOReader's streaming wait is interruptible", .serialized, .offCooperativePool)
struct AVIOReaderInterruptibleWaitTests {

    /// A length-less chunked 200 (so the reader can size nothing and streams forward-only): `firstBytes` of 0x47,
    /// then nothing until `release()`, then `firstBytes` of 0x48 and the end of the body.
    private final class StallingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let firstBytes: Int
        private let condition = NSCondition()
        private var released = false
        private var stopped = false

        init?(firstBytes: Int) {
            self.firstBytes = firstBytes
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [self] fd in
                Thread.detachNewThread { [self] in serve(fd) }
                return true
            }
        }

        func release() { condition.withLock { released = true; condition.broadcast() } }

        func stop() {
            condition.withLock { stopped = true; condition.broadcast() }
            listener.stop()
        }

        private func send(_ fd: Int32, _ bytes: [UInt8]) {
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, $0.count - sent, 0) }
                guard n > 0 else { return }
                sent += n
            }
        }

        private func serve(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { Darwin.close(fd); return }
                request.append(contentsOf: buf[0..<n])
            }
            let isHead = request.starts(with: Data("HEAD".utf8))
            send(fd, Array(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
                + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                + (isHead ? "" : String(2 * firstBytes, radix: 16) + "\r\n")).utf8))
            if !isHead {
                send(fd, [UInt8](repeating: 0x47, count: firstBytes))
                condition.lock()
                while !released, !stopped { condition.wait() }
                let go = !stopped
                condition.unlock()
                if go { send(fd, [UInt8](repeating: 0x48, count: firstBytes) + Array("\r\n0\r\n\r\n".utf8)) }
            }
            shutdown(fd, SHUT_WR)
            condition.lock()
            while !stopped { condition.wait() }
            condition.unlock()
            Darwin.close(fd)
        }
    }

    /// A read run off the test's thread, as the demuxer's pump runs it.
    private final class PendingRead: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Int32?
        private var first: UInt8 = 0

        init(_ reader: AVIOReader, size: Int32) {
            Thread.detachNewThread { [self] in
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
                defer { buf.deallocate() }
                let n = reader.read(into: buf, size: size)
                lock.withLock { result = n; first = buf[0] }
            }
        }

        var value: Int32? { lock.withLock { result } }
        var firstByte: UInt8 { lock.withLock { first } }
    }

    @Test("an interrupted streaming read returns at once and the stream reads on after it", .timeLimit(.minutes(1)))
    func streamingWaitEndsOnInterrupt() async throws {
        let firstBytes = 64 * 1024
        let origin = try #require(StallingOrigin(firstBytes: firstBytes))
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!, prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Everything the origin sent before it stalled.
        var drained = 0
        while drained < firstBytes {
            let read = PendingRead(reader, size: Int32(firstBytes - drained))
            try await waitFor { read.value != nil }
            let n = try #require(read.value)
            try #require(n > 0, "the first bytes read \(n)")
            drained += Int(n)
        }

        // The next read waits for bytes the origin holds back; the restart interrupts it.
        let parked = PendingRead(reader, size: 4096)
        // test-wait: the read has to be inside its wait for the interrupt to be the thing that ends it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(parked.value == nil, "the read did not wait: \(String(describing: parked.value))")
        reader.interruptRead()
        // The bound is the assertion: the wait ran its full 15 s before.
        let ended = try await waitFor(upTo: .seconds(5)) { parked.value != nil }
        #expect(ended, "the interrupt did not end the streaming wait")
        #expect(parked.value == -1)
        reader.endReadInterrupt()

        origin.release()
        let next = PendingRead(reader, size: 4096)
        try await waitFor { next.value != nil }
        #expect(next.value == 4096, "the read after the interrupt got \(String(describing: next.value))")
        #expect(next.firstByte == 0x48, "the stream did not go on where it stopped")
    }
}
