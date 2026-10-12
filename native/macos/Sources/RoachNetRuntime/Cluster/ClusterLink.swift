#if canImport(CryptoKit) && canImport(Darwin)
import Darwin
import Foundation

/// One TCP connection between two Macs of a cluster: length-prefixed frames,
/// sealed once the handshake has proved both ends hold the pairing secret.
/// A message is a JSON header plus an optional binary payload (activations,
/// shard bytes).
final class ClusterLink {
    static let maxFrame = 96 << 20
    let fd: Int32
    let remote: String
    private(set) var peerID = ""
    private var channel: ClusterChannel?
    private let lock = NSLock()

    init(fd: Int32, remote: String) {
        self.fd = fd
        self.remote = remote
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed { Darwin.close(fd); closed = true }
    }
    private var closed = false

    /// `host:port`, with `.local` names resolved by the system (Bonjour hostnames work).
    static func connect(_ address: String, defaultPort: UInt16, timeout: TimeInterval = 5) throws -> ClusterLink {
        let (host, port) = parse(address, defaultPort: defaultPort)
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw ClusterError.unreachable("Couldn't find \(host) on the network.")
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let started = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                var ready = started == 0
                if !ready && errno == EINPROGRESS {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&poller, 1, Int32(timeout * 1_000)) == 1 {
                        var failure: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
                        ready = failure == 0
                    }
                }
                if ready {
                    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                    return ClusterLink(fd: fd, remote: "\(host):\(port)")
                }
                Darwin.close(fd)
            }
            cursor = info.pointee.ai_next
        }
        throw ClusterError.unreachable("\(host):\(port) didn't answer. Is RoachNet running there with Cluster on?")
    }

    static func parse(_ address: String, defaultPort: UInt16) -> (String, UInt16) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let parts = trimmed.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (trimmed, defaultPort)
    }

    func setTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Bytes and frames

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw ClusterError.unreachable("The connection to \(remote) dropped.") }
                offset += sent
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let got = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if got < 0 && errno == EINTR { continue }
                if got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw ClusterError.unreachable("\(remote) stopped answering.")
                }
                guard got > 0 else { throw ClusterError.unreachable("The connection to \(remote) closed.") }
                offset += got
            }
        }
        return data
    }

    private func sendFrame(_ payload: Data) throws {
        let body: Data
        if channel != nil { body = try channel!.seal(payload) } else { body = payload }
        var length = UInt32(body.count).bigEndian
        try writeAll(Data(bytes: &length, count: 4) + body)
    }

    private func receiveFrame() throws -> Data {
        let header = try readExactly(4)
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
        guard length <= ClusterLink.maxFrame else { throw ClusterError.protocolError("\(remote) sent a frame that is too large.") }
        let body = try readExactly(length)
        guard channel != nil else { return body }
        do { return try channel!.open(body) } catch { throw ClusterError.protocolError("A frame from \(remote) failed its integrity check.") }
    }

    // MARK: Handshake

    /// The connecting side. Throws `wrongCluster` when the other Mac holds a different secret.
    func handshakeAsInitiator(key: ClusterKey, nodeID: Data) throws {
        let nonce = ClusterHandshake.nonce()
        try sendFrame(ClusterHandshake.magic + nodeID + nonce)
        let reply = try receiveFrame()
        guard reply.count == 16 + 32 + 32 else { throw ClusterError.protocolError("\(remote) isn't a RoachNet Cluster node.") }
        let theirID = reply.prefix(16), theirNonce = reply.dropFirst(16).prefix(32), theirProof = reply.suffix(32)
        guard ClusterHandshake.proof(key, "responder", nonce, Data(theirNonce), nodeID, Data(theirID)) == Data(theirProof) else {
            throw ClusterError.wrongCluster
        }
        try sendFrame(ClusterHandshake.proof(key, "initiator", nonce, Data(theirNonce), nodeID, Data(theirID)))
        channel = ClusterChannel(key: key, initiatorNonce: nonce, responderNonce: Data(theirNonce), initiator: true)
        peerID = Data(theirID).map { String(format: "%02x", $0) }.joined()
        let (welcome, _) = try receive()
        guard welcome["ok"].truthy else { throw ClusterError.wrongCluster }
    }

    /// The listening side.
    func handshakeAsResponder(key: ClusterKey, nodeID: Data) throws {
        let hello = try receiveFrame()
        guard hello.count == 4 + 16 + 32, hello.prefix(4) == ClusterHandshake.magic else {
            throw ClusterError.protocolError("\(remote) isn't a RoachNet Cluster node.")
        }
        let theirID = Data(hello.dropFirst(4).prefix(16)), theirNonce = Data(hello.suffix(32))
        let nonce = ClusterHandshake.nonce()
        try sendFrame(nodeID + nonce + ClusterHandshake.proof(key, "responder", theirNonce, nonce, theirID, nodeID))
        let proof = try receiveFrame()
        guard proof == ClusterHandshake.proof(key, "initiator", theirNonce, nonce, theirID, nodeID) else { throw ClusterError.wrongCluster }
        channel = ClusterChannel(key: key, initiatorNonce: theirNonce, responderNonce: nonce, initiator: false)
        peerID = theirID.map { String(format: "%02x", $0) }.joined()
        try send(["ok": true])
    }

    // MARK: Messages

    func send(_ header: JSON, _ payload: Data = Data()) throws {
        let head = header.serializedData()
        var length = UInt32(head.count).bigEndian
        try sendFrame(Data(bytes: &length, count: 4) + head + payload)
    }

    func receive() throws -> (JSON, Data) {
        let frame = try receiveFrame()
        guard frame.count >= 4 else { throw ClusterError.protocolError("\(remote) sent an empty message.") }
        let length = Int(frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
        guard length <= frame.count - 4 else { throw ClusterError.protocolError("\(remote) sent a broken message.") }
        let header = (try? JSON.parse(String(decoding: frame.dropFirst(4).prefix(length), as: UTF8.self))) ?? .null
        return (header, Data(frame.dropFirst(4 + length)))
    }

    /// One request and its reply; one at a time per link.
    func request(_ header: JSON, _ payload: Data = Data(), timeout: TimeInterval = 300) throws -> (JSON, Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw ClusterError.unreachable("The connection to \(remote) is closed.") }
        setTimeout(timeout)
        try send(header, payload)
        let reply = try receive()
        if let message = reply.0["error"].stringValue { throw ClusterError.remote(message) }
        return reply
    }
}

/// Accepts cluster connections on a TCP port.
final class ClusterListener {
    let fd: Int32
    let port: UInt16
    private var running = true

    init(host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClusterError.unreachable("Couldn't open the cluster port.") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw ClusterError.unreachable("The cluster port \(port) is in use.")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    func run(_ handle: @escaping (ClusterLink) -> Void) {
        let thread = Thread { [weak self] in
            while let self, self.running {
                var peer = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(self.fd, $0, &length) } }
                guard client >= 0 else { if errno == EINTR { continue } else { break } }
                let remote = String(cString: inet_ntoa(peer.sin_addr)) + ":\(UInt16(bigEndian: peer.sin_port))"
                let link = ClusterLink(fd: client, remote: remote)
                Thread.detachNewThread { handle(link) }
            }
        }
        thread.name = "roachnet-cluster-listener"
        thread.start()
    }

    func stop() {
        running = false
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
#endif
