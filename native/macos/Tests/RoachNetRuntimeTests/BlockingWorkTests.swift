import XCTest
@testable import RoachNetRuntime

/// Work that blocks has to run all at once, not one CPU's worth at a time. On
/// Linux, dispatch's global queues run about one block per CPU and add workers
/// only slowly. So eight status requests that each waited on other threads
/// took seconds on two CPUs (ROA-90).
final class BlockingWorkTests: XCTestCase {
    /// Lets `count` arrivals through together, or gives up at a deadline.
    private final class Barrier {
        private let condition = NSCondition()
        private let count: Int
        private var arrived = 0

        init(count: Int) { self.count = count }

        /// Whether all `count` arrived before `timeout`.
        func arriveAndWait(timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            arrived += 1
            if arrived >= count {
                condition.broadcast()
                return true
            }
            let deadline = Date().addingTimeInterval(timeout)
            while arrived < count {
                if !condition.wait(until: deadline) { return arrived >= count }
            }
            return true
        }
    }

    func testAllRunsEveryClosureAtTheSameTime() {
        let barrier = Barrier(count: 8)
        let together = OrgLocked(0)
        let started = Date()
        BlockingWork.all("test.all", (0..<8).map { _ -> () -> Void in
            { if barrier.arriveAndWait(timeout: 5) { together.mutate { $0 += 1 } } }
        })
        XCTAssertEqual(together.value, 8, "all eight closures ran at the same time")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testAllWithNoClosuresReturns() {
        BlockingWork.all("test.none", [])
    }

    func testServerServesBlockedConnectionsAtTheSameTime() throws {
        // Each handler waits until all eight requests are being handled, as
        // eight status reads wait on one shared probe.
        let barrier = Barrier(count: 8)
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { _ in
            HTTPResponse(status: barrier.arriveAndWait(timeout: 5) ? 200 : 503)
        }
        try server.start()
        defer { server.stop() }
        let statuses = OrgLocked<[Int]>([])
        let started = Date()
        BlockingWork.all("test.client", (0..<8).map { _ -> () -> Void in
            {
                let status = Self.status(ofGetTo: server.port)
                statuses.mutate { $0.append(status) }
            }
        })
        XCTAssertEqual(statuses.value, Array(repeating: 200, count: 8), "every request was handled while the others waited")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    /// The status code of one GET over a plain socket. URLSession would allow
    /// only six connections to one host at a time, which is the client's limit,
    /// not the server's.
    private static func status(ofGetTo port: UInt16) -> Int {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return -1 }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return -1 }
        let request = Array("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return -1 }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return -1 }
        // "HTTP/1.1 200 OK"
        let fields = String(decoding: buffer[0..<count], as: UTF8.self).split(separator: " ")
        return fields.count > 1 ? Int(fields[1]) ?? -1 : -1
    }
}
