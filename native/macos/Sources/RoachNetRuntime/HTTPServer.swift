import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct HTTPRequest {
    public var method: String
    public var target: String
    public var headers: [String: String]   // lowercased names
    public var remoteAddress: String
    fileprivate var bodyReader: (() throws -> Data)?
    private var cachedBody: Data?

    public init(method: String, target: String, headers: [String: String], remoteAddress: String = "127.0.0.1", body: Data? = nil) {
        self.method = method
        self.target = target
        self.headers = headers
        self.remoteAddress = remoteAddress
        self.cachedBody = body
        self.bodyReader = nil
    }

    fileprivate init(method: String, target: String, headers: [String: String], remoteAddress: String, reader: @escaping () throws -> Data) {
        self.method = method
        self.target = target
        self.headers = headers
        self.remoteAddress = remoteAddress
        self.bodyReader = reader
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Reads the full request body once. Throws `BodyTooLarge` past `limit`.
    public mutating func body() throws -> Data {
        if let cachedBody { return cachedBody }
        let data = try bodyReader?() ?? Data()
        cachedBody = data
        bodyReader = nil
        return data
    }
}

/// Writes a streamed response body; `write` returns false once the client is gone.
public final class HTTPStreamWriter {
    fileprivate let sink: (Data) -> Bool
    public private(set) var isClosed = false
    fileprivate init(sink: @escaping (Data) -> Bool) { self.sink = sink }
    @discardableResult
    public func write(_ data: Data) -> Bool {
        if isClosed { return false }
        if !sink(data) { isClosed = true }
        return !isClosed
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
    /// When set, the body is produced incrementally (no content-length; the
    /// connection closes when the closure returns).
    public var stream: ((HTTPStreamWriter) -> Void)?

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = nil
    }

    public static func ndjsonStream(_ produce: @escaping (HTTPStreamWriter) -> Void) -> HTTPResponse {
        var response = HTTPResponse(status: 200, headers: [("content-type", "application/x-ndjson"), ("cache-control", "no-store")])
        response.stream = produce
        return response
    }

    public static func json(_ status: Int, _ value: JSON, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        let payload = value.serializedData()
        return HTTPResponse(status: status, headers: [
            ("content-type", "application/json; charset=utf-8"),
            ("cache-control", "no-store"),
        ] + extraHeaders, body: payload)
    }
}

public struct BodyTooLarge: Error { public let limit: Int }

/// Minimal HTTP/1.1 server on POSIX sockets, bound to loopback only.
/// One request per connection (`Connection: close`) keeps it predictable.
public final class LoopbackHTTPServer {
    public typealias Handler = (inout HTTPRequest) -> HTTPResponse

    private let host: String
    private let requestedPort: UInt16
    private let maxBodyBytes: Int
    private let handler: Handler
    private var socketFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "org.roachnet.runtime.accept")
    private let workQueue = DispatchQueue(label: "org.roachnet.runtime.work", attributes: .concurrent)
    public private(set) var port: UInt16 = 0

    public init(host: String, port: UInt16, maxBodyBytes: Int, handler: @escaping Handler) {
        self.host = host
        self.requestedPort = port
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let isIPv6 = host.contains(":")
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, streamType, 0)
        guard fd >= 0 else { throw RuntimeError("socket() failed: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let bindResult: Int32
        if isIPv6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = requestedPort.bigEndian
            _ = host.withCString { inet_pton(AF_INET6, $0, &address.sin6_addr) }
            bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = requestedPort.bigEndian
            let resolvedHost = host == "localhost" ? "127.0.0.1" : host
            _ = resolvedHost.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RuntimeError("listen EADDRINUSE or bind failure on \(host):\(requestedPort): \(message)")
        }
        guard listen(fd, 128) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RuntimeError("listen() failed: \(message)")
        }

        // Resolve the bound port (PORT=0 asks the OS for one).
        if isIPv6 {
            var address = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: address.sin6_port)
        } else {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: address.sin_port)
        }

        socketFD = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if socketFD >= 0 {
            shutdown(socketFD, Int32(SHUT_RDWR))
            close(socketFD)
            socketFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketFD, $0, &length) }
            }
            if client < 0 {
                if !running { return }
                if errno == EINTR || errno == ECONNABORTED { continue }
                usleep(10_000)
                continue
            }
            let remote = LoopbackHTTPServer.describe(address)
            workQueue.async { [weak self] in self?.serve(client, remote: remote) }
        }
    }

    private static func describe(_ storage: sockaddr_storage) -> String {
        var storage = storage
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if storage.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer -> String in
                    var addr = pointer.pointee.sin6_addr
                    inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
                    return String(cString: buffer)
                }
            }
        }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String in
                var addr = pointer.pointee.sin_addr
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
                return String(cString: buffer)
            }
        }
    }

    private func serve(_ fd: Int32, remote: String) {
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connection = SocketReader(fd: fd)
        defer {
            shutdown(fd, Int32(SHUT_WR))
            // Drain briefly so unread request bytes do not turn into a reset
            // before the client reads our response.
            var drainTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &drainTimeout, socklen_t(MemoryLayout<timeval>.size))
            var scratch = [UInt8](repeating: 0, count: 16_384)
            var drained = 0
            while drained < 8 * 1024 * 1024 {
                let count = recv(fd, &scratch, scratch.count, 0)
                if count <= 0 { break }
                drained += count
            }
            close(fd)
        }

        guard let head = connection.readHead(limit: 64 * 1024) else {
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else {
            send(fd, HTTPResponse.json(400, ["error": "Bad request"]))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let maxBody = maxBodyBytes
        let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        // A malformed or negative Content-Length is a protocol error, not a
        // zero-length body: `-1` would otherwise reach the reader as a range
        // bound and trap the process before any authentication runs.
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                send(fd, HTTPResponse.json(400, ["error": "Invalid Content-Length"]))
                return
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        var request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            headers: headers,
            remoteAddress: remote,
            reader: {
                if chunked { return try connection.readChunkedBody(limit: maxBody) }
                if contentLength > maxBody { throw BodyTooLarge(limit: maxBody) }
                return try connection.readBody(length: contentLength, limit: maxBody)
            }
        )

        if headers["expect"]?.lowercased() == "100-continue" {
            writeAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let response = handler(&request)
        send(fd, response)
    }

    private func send(_ fd: Int32, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(LoopbackHTTPServer.reason(response.status))\r\n"
        var hasLength = false
        for (name, value) in response.headers {
            if name.lowercased() == "content-length" { hasLength = true }
            if name.lowercased() == "connection" { continue }
            head += "\(name): \(value)\r\n"
        }
        if !hasLength && response.stream == nil { head += "content-length: \(response.body.count)\r\n" }
        head += "connection: close\r\n\r\n"
        guard writeAll(fd, Array(head.utf8)) else { return }
        if !response.body.isEmpty { writeAll(fd, Array(response.body)) }
        if let stream = response.stream {
            stream(HTTPStreamWriter { [self] data in self.writeAll(fd, Array(data)) })
        }
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                #if canImport(Darwin)
                return Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
                #else
                return Glibc.send(fd, buffer.baseAddress, buffer.count, Int32(MSG_NOSIGNAL))
                #endif
            }
            if written <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}

/// Buffered reader over a connected socket.
final class SocketReader {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) { self.fd = fd }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                return true
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
    }

    func readHead(limit: Int) -> String? {
        let terminator: [UInt8] = [13, 10, 13, 10]
        var searchStart = 0
        while true {
            if buffer.count >= 4 {
                var index = max(0, searchStart - 3)
                while index + 4 <= buffer.count {
                    if buffer[index] == 13, buffer[index + 1] == 10, buffer[index + 2] == 13, buffer[index + 3] == 10 {
                        let head = String(decoding: buffer[0..<index], as: UTF8.self)
                        buffer.removeFirst(index + terminator.count)
                        return head
                    }
                    index += 1
                }
                searchStart = buffer.count
            }
            if buffer.count > limit { return nil }
            if !fill() { return nil }
        }
    }

    func readBody(length: Int, limit: Int) throws -> Data {
        if length > limit { throw BodyTooLarge(limit: limit) }
        if length <= 0 { return Data() }
        while buffer.count < length {
            if !fill() { break }
        }
        let take = min(length, buffer.count)
        let data = Data(buffer[0..<take])
        buffer.removeFirst(take)
        return data
    }

    private func readLine() -> String? {
        while true {
            if let index = buffer.firstIndex(of: 10) {
                var lineBytes = Array(buffer[0..<index])
                buffer.removeFirst(index + 1)
                if lineBytes.last == 13 { lineBytes.removeLast() }
                return String(decoding: lineBytes, as: UTF8.self)
            }
            if !fill() { return nil }
        }
    }

    func readChunkedBody(limit: Int) throws -> Data {
        var data = Data()
        while true {
            guard let sizeLine = readLine() else { break }
            let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? "0"
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { break }
            if size == 0 {
                _ = readLine()
                break
            }
            // Compare against the limit before any addition so an oversized
            // chunk header cannot overflow `data.count + size`.
            if size > limit || data.count > limit - size { throw BodyTooLarge(limit: limit) }
            while buffer.count < size + 2 {
                if !fill() { break }
            }
            let take = min(size, buffer.count)
            data.append(contentsOf: buffer[0..<take])
            buffer.removeFirst(min(buffer.count, size + 2))
        }
        return data
    }
}
