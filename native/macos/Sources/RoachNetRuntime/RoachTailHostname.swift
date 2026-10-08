import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native port of scripts/lib/roachtail_hostname.mjs and
/// scripts/install-roachtail-hostname.mjs: keeps a marked RoachNet block in the
/// hosts file so `http://RoachNet:<port>` resolves to the contained loopback lane.
public enum RoachTailHostname {
    public static let defaultHostname = "RoachNet"
    public static let blockBegin = "# >>> RoachNet local alias >>>"
    public static let blockEnd = "# <<< RoachNet local alias <<<"

    public static func hostname(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let explicit = environment["ROACHNET_LOCAL_HOSTNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? defaultHostname : explicit
    }

    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return value.lowercased()
    }

    static func isLoopback(_ address: String) -> Bool {
        let normalized = normalize(address)
        return normalized == "127.0.0.1" || normalized == "::1"
    }

    public static func block(for hostname: String) -> String {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultHostname : hostname
        return [blockBegin, "127.0.0.1 \(host)", "::1 \(host)", blockEnd].joined(separator: "\n")
    }

    public static func strip(_ content: String) -> String {
        var kept: [Substring] = []
        var skipping = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.hasSuffix("\r") ? line.dropLast() : line
            let trimmed = trimmedLine.trimmingCharacters(in: .whitespaces)
            if trimmed == blockBegin { skipping = true; continue }
            if trimmed == blockEnd { skipping = false; continue }
            if !skipping { kept.append(trimmedLine) }
        }
        var joined = kept.joined(separator: "\n")
        while joined.contains("\n\n\n") { joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while let last = joined.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            joined.unicodeScalars.removeLast()
        }
        return joined
    }

    public static func apply(to content: String, hostname: String) -> String {
        let stripped = strip(content)
        let aliasBlock = block(for: hostname)
        return stripped.isEmpty ? "\(aliasBlock)\n" : "\(stripped)\n\n\(aliasBlock)\n"
    }

    public static func hasAlias(_ content: String, hostname: String) -> Bool {
        let host = normalize(hostname)
        for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, isLoopback(tokens[0]) else { continue }
            if tokens.dropFirst().contains(where: { normalize($0) == host }) { return true }
        }
        return false
    }

    public static func resolvesToLoopback(_ hostname: String) -> Bool {
        (DNS.addresses(hostname) ?? []).contains(where: isLoopback)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Privileged rewrite used only when the hosts file is not writable by the user.
    public static func privilegedShellCommand(hostname: String, hostsFile: String) -> String {
        [
            "HOSTS_FILE=\(shellQuote(hostsFile))",
            "ROACHNET_HOSTNAME=\(shellQuote(hostname))",
            "ROACHNET_ALIAS_BEGIN=\(shellQuote(blockBegin))",
            "ROACHNET_ALIAS_END=\(shellQuote(blockEnd))",
            "TMP_ROACHNET_HOSTS=$(mktemp \"${TMPDIR:-/tmp}/roachnet-hosts.XXXXXX\")",
            "trap 'rm -f \"$TMP_ROACHNET_HOSTS\" \"$TMP_ROACHNET_HOSTS.next\"' EXIT",
            "awk -v begin=\"$ROACHNET_ALIAS_BEGIN\" -v end=\"$ROACHNET_ALIAS_END\" 'BEGIN { skip = 0 } $0 == begin { skip = 1; next } $0 == end { skip = 0; next } !skip { print }' \"$HOSTS_FILE\" > \"$TMP_ROACHNET_HOSTS\"",
            "{",
            "  cat \"$TMP_ROACHNET_HOSTS\"",
            "  printf '\\n%s\\n127.0.0.1 %s\\n::1 %s\\n%s\\n' \"$ROACHNET_ALIAS_BEGIN\" \"$ROACHNET_HOSTNAME\" \"$ROACHNET_HOSTNAME\" \"$ROACHNET_ALIAS_END\"",
            "} > \"$TMP_ROACHNET_HOSTS.next\"",
            "cat \"$TMP_ROACHNET_HOSTS.next\" > \"$HOSTS_FILE\"",
            "dscacheutil -flushcache >/dev/null 2>&1 || true",
            "killall -HUP mDNSResponder >/dev/null 2>&1 || true",
        ].joined(separator: "; ")
    }

    static func flushResolverCache() {
        guard Host.platform == "darwin" else { return }
        Processes.run("/bin/sh", ["-c", "dscacheutil -flushcache >/dev/null 2>&1 || true; killall -HUP mDNSResponder >/dev/null 2>&1 || true"], timeoutMs: 10_000)
    }

    public struct Outcome {
        public let hostname: String
        public let hostsFile: String
        public let changed: Bool
        public let resolved: Bool?
    }

    /// Ensures the alias exists. Writes directly when the file is writable; for
    /// the system hosts file it falls back to a one-time administrator prompt.
    public static func provision(hostname: String, hostsFile: String, allowPrivilegePrompt: Bool) throws -> Outcome {
        let isSystemHosts = hostsFile == "/etc/hosts"
        guard let current = try? String(contentsOfFile: hostsFile, encoding: .utf8) else {
            throw RuntimeError("RoachNet could not read \(hostsFile).")
        }
        if hasAlias(current, hostname: hostname) {
            if isSystemHosts { flushResolverCache() }
            return Outcome(hostname: hostname, hostsFile: hostsFile, changed: false, resolved: isSystemHosts ? resolvesToLoopback(hostname) : nil)
        }

        let next = apply(to: current, hostname: hostname)
        if access(hostsFile, W_OK) == 0 {
            // Write in place (not rename) so the hosts file keeps its owner and mode.
            guard let handle = FileHandle(forWritingAtPath: hostsFile) else {
                throw RuntimeError("RoachNet could not open \(hostsFile) for writing.")
            }
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(next.utf8))
            flushResolverCache()
        } else {
            guard allowPrivilegePrompt, Host.platform == "darwin" else {
                throw RuntimeError("RoachNet could not update \(hostsFile) without elevated access. Provision the RoachTail alias manually or allow the administrator prompt.")
            }
            let shellCommand = "/bin/zsh -c \(shellQuote(privilegedShellCommand(hostname: hostname, hostsFile: hostsFile)))"
            let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let result = Processes.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeoutMs: 180_000)
            guard result.status == 0 else {
                let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RuntimeError("The administrator prompt for the RoachTail alias was not completed\(detail.isEmpty ? "" : ": \(detail)").")
            }
        }
        return Outcome(hostname: hostname, hostsFile: hostsFile, changed: true, resolved: isSystemHosts ? resolvesToLoopback(hostname) : nil)
    }
}
