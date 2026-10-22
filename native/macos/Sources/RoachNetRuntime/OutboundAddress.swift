import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OutboundAddress {
    enum Kind: Equatable {
        case `public`
        case linkLocal
        case disallowed
        case local
    }

    static func kind(of bytes: [UInt8]) -> Kind {
        switch bytes.count {
        case 4: return kindV4(bytes[0], bytes[1])
        case 16: return kindV6(bytes)
        default: return .disallowed
        }
    }

    private static func kindV4(_ a: UInt8, _ b: UInt8) -> Kind {
        switch a {
        case 0: return .disallowed
        case 10, 127: return .local
        case 100 where (64...127).contains(b): return .local
        case 169 where b == 254: return .linkLocal
        case 172 where (16...31).contains(b): return .local
        case 192 where b == 168: return .local
        case 198 where b == 18 || b == 19: return .local
        case 224...255: return .disallowed
        default: return .public
        }
    }

    private static func kindV6(_ bytes: [UInt8]) -> Kind {
        func zero(_ range: Range<Int>) -> Bool { bytes[range].allSatisfy { $0 == 0 } }
        if zero(0..<16) { return .disallowed }
        if zero(0..<15) && bytes[15] == 1 { return .local }
        if zero(0..<10) && bytes[10] == 0xff && bytes[11] == 0xff { return kindV4(bytes[12], bytes[13]) }
        if zero(0..<12) { return kindV4(bytes[12], bytes[13]) }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b {
            if zero(4..<12) { return kindV4(bytes[12], bytes[13]) }
            if bytes[4] == 0x00 && bytes[5] == 0x01 { return .local }
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return kindV4(bytes[2], bytes[3]) }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return .local }
        if bytes[0] & 0xfe == 0xfc { return .local }
        if bytes[0] == 0xff { return .disallowed }
        return .public
    }

    private static func unscoped(_ address: String) -> String {
        address.firstIndex(of: "%").map { String(address[..<$0]) } ?? address
    }

    static func refusal(_ address: String, blockPrivate: Bool) -> String? {
        let host = address.lowercased()
        if host.isEmpty { return "empty address" }
        let kind: Kind
        if host == "localhost" || host.hasSuffix(".localhost") {
            kind = .local
        } else if let bytes = IPAddress.bytes(unscoped(host)) {
            kind = Self.kind(of: bytes)
        } else {
            return blockPrivate ? "not an IP address: \(host)" : nil
        }
        switch kind {
        case .public: return nil
        case .linkLocal: return "link-local address blocked (SSRF metadata risk): \(host)"
        case .disallowed: return "disallowed address: \(host)"
        case .local: return blockPrivate ? "private/loopback address blocked: \(host)" : nil
        }
    }

    static func kinds(ofHost host: String) -> [Kind]? {
        var bare = host.lowercased()
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.hasSuffix(".") && !bare.hasSuffix("..") { bare.removeLast() }
        if bare.isEmpty { return nil }
        if bare == "localhost" || bare.hasSuffix(".localhost") { return [.local] }
        if let bytes = IPAddress.bytes(unscoped(bare)) { return [kind(of: bytes)] }
        guard let addresses = DNS.addresses(bare), !addresses.isEmpty else { return nil }
        return addresses.map { IPAddress.bytes(unscoped($0)).map(kind(of:)) ?? .disallowed }
    }

    static func redirectRefusal(from origin: URL?, to target: URL?) -> String? {
        guard let target, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "an address that isn't http or https"
        }
        if let host = origin?.host, let kinds = kinds(ofHost: host), kinds.allSatisfy({ $0 == .local }) { return nil }
        guard let host = target.host, !host.isEmpty else { return "an address with no host" }
        guard let kinds = kinds(ofHost: host) else { return "\(host), which doesn't resolve" }
        if kinds.contains(where: { $0 != .public }) { return "\(host), on this Mac or a private network" }
        return nil
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    @discardableResult
    static func decide(
        _ task: URLSessionTask, _ response: HTTPURLResponse, _ request: URLRequest,
        _ completionHandler: @escaping (URLRequest?) -> Void
    ) -> String? {
        if let reason = OutboundAddress.redirectRefusal(from: response.url ?? task.currentRequest?.url, to: request.url)
        {
            RuntimeLog.write("redirect not followed: \(reason)")
            completionHandler(nil)
            return reason
        }
        completionHandler(request)
        return nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        RedirectGuard.decide(task, response, request, completionHandler)
    }
}
