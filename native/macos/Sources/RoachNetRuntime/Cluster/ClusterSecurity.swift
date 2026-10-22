#if canImport(CryptoKit)
import CryptoKit
import Foundation

struct ClusterKey: Equatable {
    let bytes: Data

    static func random() -> ClusterKey {
        ClusterKey(bytes: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    init(bytes: Data) { self.bytes = bytes }

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    var code: String {
        var bits = 0
        var value = 0
        var out: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(ClusterKey.alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(ClusterKey.alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(
            separator: "-")
    }

    init?(code: String) {
        let normalized = code.uppercased().replacingOccurrences(of: "O", with: "0").replacingOccurrences(
            of: "I", with: "1"
        )
        .replacingOccurrences(of: "L", with: "1").filter { !"- ".contains($0) }
        guard normalized.count == 26 else { return nil }
        var bits = 0
        var value = 0
        var bytes = Data()
        for character in normalized {
            guard let index = ClusterKey.alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    var fingerprint: String {
        SHA256.hash(data: bytes + Data("roachnet-cluster".utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    var symmetric: SymmetricKey { SymmetricKey(data: bytes) }
}

struct ClusterChannel {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(key: ClusterKey, initiatorNonce: Data, responderNonce: Data, initiator: Bool) {
        let salt = initiatorNonce + responderNonce
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key.symmetric, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        let forward = derive("roachnet-cluster initiator to responder")
        let backward = derive("roachnet-cluster responder to initiator")
        sendKey = initiator ? forward : backward
        receiveKey = initiator ? backward : forward
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: ClusterChannel.nonce(sent))
        sent += 1
        var out = Data(box.ciphertext)
        out.append(box.tag)
        return out
    }

    mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw ClusterError.protocolError("A frame is too short.") }
        let box = try ChaChaPoly.SealedBox(
            nonce: ClusterChannel.nonce(received), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try ChaChaPoly.open(box, using: receiveKey)
        received += 1
        return plain
    }
}

enum ClusterHandshake {
    static let magic = Data("RNC1".utf8)

    static func proof(
        _ key: ClusterKey, _ role: String, _ initiatorNonce: Data, _ responderNonce: Data, _ initiatorID: Data,
        _ responderID: Data
    ) -> Data {
        let message = Data(role.utf8) + initiatorNonce + responderNonce + initiatorID + responderID
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key.symmetric))
    }

    static func nonce() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}
#endif

enum ClusterError: Error, CustomStringConvertible {
    case notPaired
    case wrongCluster
    case unreachable(String)
    case protocolError(String)
    case remote(String)

    var description: String {
        switch self {
        case .notPaired: return "This Mac isn't in a cluster yet."
        case .wrongCluster: return "That Mac is in a different cluster (the pairing codes don't match)."
        case .unreachable(let message): return message
        case .protocolError(let message): return message
        case .remote(let message): return message
        }
    }
}
