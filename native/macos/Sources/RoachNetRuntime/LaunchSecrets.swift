import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LaunchSecrets: Equatable {
    public static let apiTokenVariable = "ROACHNET_API_TOKEN"
    public static let apiTokenOnInputVariable = "ROACHNET_API_TOKEN_STDIN"
    public static let companionTokenVariable = "ROACHNET_COMPANION_TOKEN"
    static let longestToken = 512

    public var apiToken: String?
    public var companionToken: String?

    public init(apiToken: String? = nil, companionToken: String? = nil) {
        self.apiToken = apiToken
        self.companionToken = companionToken
    }

    public struct MissingLaunchToken: Error, CustomStringConvertible {
        public var description: String {
            "the launch token was to come on standard input and none came, so the local API would have no token. The runtime doesn't start without it."
        }
    }

    public static func adopt(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Int32 = STDIN_FILENO
    ) throws -> LaunchSecrets {
        defer {
            for name in [apiTokenVariable, apiTokenOnInputVariable, companionTokenVariable] { unsetenv(name) }
        }
        var secrets = LaunchSecrets(
            apiToken: nonEmpty(environment[apiTokenVariable]),
            companionToken: nonEmpty(environment[companionTokenVariable]))
        guard environment[apiTokenOnInputVariable] == "1" else { return secrets }
        let token = readToken(from: input)
        detach(input)
        guard let token else { throw MissingLaunchToken() }
        secrets.apiToken = token
        return secrets
    }

    static func readToken(from fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < longestToken {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 || byte == UInt8(ascii: "\n") { break }
            bytes.append(byte)
        }
        return nonEmpty(String(decoding: bytes, as: UTF8.self))
    }

    static func detach(_ fd: Int32) {
        let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { return }
        if null != fd {
            _ = dup2(null, fd)
            close(null)
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
