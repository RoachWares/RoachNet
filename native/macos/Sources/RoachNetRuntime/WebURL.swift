import Foundation

public struct WebURL: CustomStringConvertible {
    public var scheme: String
    public var username: String = ""
    public var password: String = ""
    public var hostname: String = ""
    public var port: String = ""
    public var pathname: String = ""
    public var query: String? = nil
    public var fragment: String? = nil
    public var hasAuthority: Bool = false

    static let specialSchemes: [String: String] = [
        "http": "80", "https": "443", "ws": "80", "wss": "443", "ftp": "21", "file": "",
    ]

    public var isSpecial: Bool { WebURL.specialSchemes[scheme] != nil }
    public var `protocol`: String { scheme + ":" }
    public var host: String { port.isEmpty ? hostname : "\(hostname):\(port)" }
    public var search: String {
        get { (query?.isEmpty ?? true) ? "" : "?" + query! }
        set {
            var value = newValue
            if value.hasPrefix("?") { value.removeFirst() }
            query = value.isEmpty ? nil : WebURL.percentEncode(value, set: .query)
        }
    }
    public var hash: String {
        get { (fragment?.isEmpty ?? true) ? "" : "#" + fragment! }
        set {
            var value = newValue
            if value.hasPrefix("#") { value.removeFirst() }
            fragment = value.isEmpty ? nil : WebURL.percentEncode(value, set: .fragment)
        }
    }

    public var bareHostname: String {
        hostname.hasPrefix("[") && hostname.hasSuffix("]") ? String(hostname.dropFirst().dropLast()) : hostname
    }

    public var origin: String {
        guard scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss" || scheme == "ftp" else {
            return "null"
        }
        return "\(scheme)://\(host)"
    }

    public var href: String { description }

    public var hasCredentials: Bool { !username.isEmpty || !password.isEmpty }

    public var withoutCredentials: String { serializedWithoutCredentials(query: query, fragment: fragment) }

    public var redacted: String { serializedWithoutCredentials(query: nil, fragment: nil) }

    public static func display(_ raw: String) -> String { WebURL(raw)?.redacted ?? "an address that can't be read" }

    private func serializedWithoutCredentials(query: String?, fragment: String?) -> String {
        var output = scheme + ":"
        if hasAuthority { output += "//" + host }
        output += pathname
        if let query { output += "?" + query }
        if let fragment { output += "#" + fragment }
        return output
    }

    public var description: String {
        var output = scheme + ":"
        if hasAuthority {
            output += "//"
            if !username.isEmpty || !password.isEmpty {
                output += username
                if !password.isEmpty { output += ":" + password }
                output += "@"
            }
            output += host
        }
        output += pathname
        if let query { output += "?" + query }
        if let fragment { output += "#" + fragment }
        return output
    }

    public init?(_ input: String, base: WebURL? = nil) {
        var text = input.trimmingCharacters(in: CharacterSet(charactersIn: "\u{00}"..."\u{20}"))
        text = text.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard !WebURL.hidesADelimiter(text) else { return nil }

        if let schemeEnd = WebURL.schemeEnd(text) {
            let scheme = String(text[..<schemeEnd]).lowercased()
            var rest = String(text[text.index(after: schemeEnd)...])
            self.scheme = scheme
            if WebURL.specialSchemes[scheme] != nil {
                if scheme == "file" {
                    hasAuthority = true
                    if rest.hasPrefix("//") {
                        rest.removeFirst(2)
                        guard parseAuthorityAndPath(rest, special: true, allowEmptyHost: true) else { return nil }
                    } else {
                        guard parseAuthorityAndPath(rest, special: true, allowEmptyHost: true, noAuthority: true) else {
                            return nil
                        }
                    }
                    return
                }
                if let base, base.scheme == scheme, !rest.hasPrefix("/"), !rest.hasPrefix("\\") {
                    self = base
                    guard self.resolveRelative(rest) else { return nil }
                    return
                }
                while rest.hasPrefix("/") || rest.hasPrefix("\\") { rest.removeFirst() }
                hasAuthority = true
                guard parseAuthorityAndPath(rest, special: true, allowEmptyHost: false) else { return nil }
                return
            }
            if rest.hasPrefix("//") {
                rest.removeFirst(2)
                hasAuthority = true
                guard parseAuthorityAndPath(rest, special: false, allowEmptyHost: true) else { return nil }
            } else {
                hasAuthority = false
                splitPathQueryFragment(rest, special: false, opaque: !rest.hasPrefix("/"))
            }
            return
        }

        guard let base else { return nil }
        self = base
        guard resolveRelative(text) else { return nil }
    }

    private mutating func resolveRelative(_ reference: String) -> Bool {
        if reference.hasPrefix("//") || (isSpecial && reference.hasPrefix("\\\\")) {
            var rest = reference
            rest.removeFirst(2)
            username = ""
            password = ""
            port = ""
            return parseAuthorityAndPath(rest, special: isSpecial, allowEmptyHost: !isSpecial)
        }
        if reference.hasPrefix("/") || (isSpecial && reference.hasPrefix("\\")) {
            splitPathQueryFragment(reference, special: isSpecial, opaque: false)
            return true
        }
        if reference.hasPrefix("?") {
            fragment = nil
            let (q, f) = WebURL.splitQueryFragment(String(reference.dropFirst()))
            query = WebURL.percentEncode(q, set: .query)
            fragment = f.map { WebURL.percentEncode($0, set: .fragment) }
            return true
        }
        if reference.hasPrefix("#") {
            fragment = WebURL.percentEncode(String(reference.dropFirst()), set: .fragment)
            return true
        }
        if reference.isEmpty {
            fragment = nil
            return true
        }
        var directory = pathname
        if let slash = directory.lastIndex(of: "/") {
            directory = String(directory[...slash])
        } else {
            directory = "/"
        }
        splitPathQueryFragment(directory + reference, special: isSpecial, opaque: false)
        return true
    }

    static func hidesADelimiter(_ text: String) -> Bool {
        let delimiters: Set<Unicode.Scalar> = ["/", "\\", "?", "#", "@", ":", "[", "]"]
        return text.contains { character in
            character.unicodeScalars.count > 1 && character.unicodeScalars.contains(where: delimiters.contains)
        }
    }

    private static func schemeEnd(_ text: String) -> String.Index? {
        guard let first = text.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII else {
            return nil
        }
        for index in text.indices {
            let character = text[index]
            if character == ":" { return index == text.startIndex ? nil : index }
            if !(character.isASCII
                && (character.isLetter || character.isNumber || character == "+" || character == "-"
                    || character == "."))
            {
                return nil
            }
        }
        return nil
    }

    private mutating func parseAuthorityAndPath(
        _ rest: String, special: Bool, allowEmptyHost: Bool, noAuthority: Bool = false
    ) -> Bool {
        var authorityEnd = rest.endIndex
        if !noAuthority {
            for index in rest.indices {
                let c = rest[index]
                if c == "/" || c == "?" || c == "#" || (special && c == "\\") {
                    authorityEnd = index
                    break
                }
            }
        } else {
            authorityEnd = rest.startIndex
        }
        if !noAuthority, authorityEnd < rest.endIndex, rest[authorityEnd] == "\\" { return false }
        var authority = String(rest[..<authorityEnd])
        let remainder = String(rest[authorityEnd...])

        if let at = authority.lastIndex(of: "@") {
            let userinfo = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                username = WebURL.percentEncode(String(userinfo[..<colon]), set: .userinfo)
                password = WebURL.percentEncode(String(userinfo[userinfo.index(after: colon)...]), set: .userinfo)
            } else {
                username = WebURL.percentEncode(userinfo, set: .userinfo)
            }
        }

        var hostPart = authority
        var portPart = ""
        if hostPart.hasPrefix("[") {
            guard let close = hostPart.firstIndex(of: "]") else { return false }
            let after = hostPart[hostPart.index(after: close)...]
            if after.hasPrefix(":") { portPart = String(after.dropFirst()) } else if !after.isEmpty { return false }
            hostPart = String(hostPart[...close])
        } else if let colon = hostPart.lastIndex(of: ":") {
            portPart = String(hostPart[hostPart.index(after: colon)...])
            hostPart = String(hostPart[..<colon])
        }

        if !portPart.isEmpty {
            guard portPart.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(portPart), number <= 65535 else {
                return false
            }
            let normalized = String(number)
            port = WebURL.specialSchemes[scheme] == normalized ? "" : normalized
        } else {
            port = ""
        }

        if hostPart.isEmpty {
            if !allowEmptyHost { return false }
            if !username.isEmpty || !password.isEmpty || !port.isEmpty { return false }
            hostname = ""
        } else if special {
            guard let parsedHost = WebURL.parseSpecialHost(hostPart) else { return false }
            hostname = parsedHost
        } else {
            guard let parsedHost = WebURL.parseOpaqueHost(hostPart) else { return false }
            hostname = parsedHost
        }

        if special || !remainder.isEmpty {
            splitPathQueryFragment(remainder, special: special, opaque: false)
        } else {
            pathname = ""
            query = nil
            fragment = nil
        }
        return true
    }

    private static func splitQueryFragment(_ text: String) -> (String, String?) {
        if let hash = text.firstIndex(of: "#") {
            return (String(text[..<hash]), String(text[text.index(after: hash)...]))
        }
        return (text, nil)
    }

    private mutating func splitPathQueryFragment(_ text: String, special: Bool, opaque: Bool) {
        var pathPart = text
        var queryPart: String? = nil
        var fragmentPart: String? = nil
        if let hash = pathPart.firstIndex(of: "#") {
            fragmentPart = String(pathPart[pathPart.index(after: hash)...])
            pathPart = String(pathPart[..<hash])
        }
        if let question = pathPart.firstIndex(of: "?") {
            queryPart = String(pathPart[pathPart.index(after: question)...])
            pathPart = String(pathPart[..<question])
        }
        if opaque {
            pathname = WebURL.percentEncode(pathPart, set: .c0)
        } else {
            if special { pathPart = pathPart.replacingOccurrences(of: "\\", with: "/") }
            pathname = WebURL.normalizePath(pathPart, special: special)
        }
        query = queryPart.map { WebURL.percentEncode($0, set: special ? .specialQuery : .query) }
        fragment = fragmentPart.map { WebURL.percentEncode($0, set: .fragment) }
    }

    private static func normalizePath(_ path: String, special: Bool) -> String {
        if path.isEmpty { return special ? "/" : "" }
        var segments: [String] = []
        var raw = path
        if raw.hasPrefix("/") { raw.removeFirst() }
        let parts = raw.components(separatedBy: "/")
        for (index, part) in parts.enumerated() {
            let lower = part.lowercased()
            let isLast = index == parts.count - 1
            if lower == ".." || lower == ".%2e" || lower == "%2e." || lower == "%2e%2e" {
                if !segments.isEmpty { segments.removeLast() }
                if isLast { segments.append("") }
            } else if lower == "." || lower == "%2e" {
                if isLast { segments.append("") }
            } else {
                segments.append(percentEncode(part, set: .path))
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func parseSpecialHost(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        if decoded.hasPrefix("[") {
            let inner = String(decoded.dropFirst().dropLast())
            guard IPAddress.version(inner) == 6 else { return nil }
            return "[" + compressIPv6(inner) + "]"
        }
        let lower = decoded.lowercased()
        let forbidden = CharacterSet(charactersIn: "\u{0}\t\n\r #/:<>?@[\\]^|%")
        if lower.unicodeScalars.contains(where: { forbidden.contains($0) || $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }
        if let ipv4 = parseIPv4(lower) { return ipv4 }
        if lower.unicodeScalars.contains(where: { !$0.isASCII }) {
            return nil
        }
        return lower
    }

    private static func parseOpaqueHost(_ raw: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "\u{0}\t\n\r #/:<>?@[\\]^|")
        if raw.unicodeScalars.contains(where: { forbidden.contains($0) }) { return nil }
        return percentEncode(raw, set: .c0)
    }

    private static func parseIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        var trimmedParts = parts
        if trimmedParts.last == "" { trimmedParts.removeLast() }
        guard !trimmedParts.isEmpty, trimmedParts.count <= 4,
            let last = trimmedParts.last, parseIPv4Number(String(last)) != nil
        else { return nil }
        var numbers: [UInt64] = []
        for part in trimmedParts {
            guard let number = parseIPv4Number(String(part)) else { return nil }
            numbers.append(number)
        }
        for number in numbers.dropLast() where number > 255 { return nil }
        let limit = UInt64(1) << (8 * UInt64(5 - numbers.count))
        guard numbers.last! < limit else { return nil }
        var value = numbers.last!
        for (index, number) in numbers.dropLast().enumerated() {
            value += number << (8 * UInt64(3 - index))
        }
        return "\(value >> 24 & 255).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    private static func parseIPv4Number(_ part: String) -> UInt64? {
        if part.isEmpty { return nil }
        var text = part
        var radix = 10
        if text.lowercased().hasPrefix("0x") {
            text = String(text.dropFirst(2))
            radix = 16
            if text.isEmpty { return 0 }
        } else if text.count > 1, text.hasPrefix("0") {
            text = String(text.dropFirst())
            radix = 8
        }
        return UInt64(text, radix: radix)
    }

    private static func compressIPv6(_ address: String) -> String {
        var raw = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &raw) }) == 1 else { return address.lowercased() }
        let bytes = withUnsafeBytes(of: raw) { Array($0) }
        var pieces: [UInt16] = []
        for i in stride(from: 0, to: 16, by: 2) { pieces.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) }
        var bestStart = -1
        var bestLength = 0
        var currentStart = -1
        var currentLength = 0
        for (index, piece) in pieces.enumerated() {
            if piece == 0 {
                if currentStart < 0 {
                    currentStart = index
                    currentLength = 0
                }
                currentLength += 1
                if currentLength > bestLength {
                    bestStart = currentStart
                    bestLength = currentLength
                }
            } else {
                currentStart = -1
            }
        }
        if bestLength < 2 { bestStart = -1 }
        var output = ""
        var index = 0
        while index < 8 {
            if index == bestStart {
                output += index == 0 ? "::" : ":"
                index += bestLength
                continue
            }
            output += String(pieces[index], radix: 16)
            if index < 7 { output += ":" }
            index += 1
        }
        return output
    }

    enum EncodeSet { case c0, fragment, query, specialQuery, path, userinfo }

    static func percentEncode(_ text: String, set: EncodeSet) -> String {
        var output = ""
        for byte in text.utf8 {
            let character = Character(Unicode.Scalar(byte))
            var encode = byte < 0x21 || byte > 0x7E
            if byte == 0x20 { encode = true }
            switch set {
            case .c0:
                encode = byte < 0x20 || byte > 0x7E
            case .fragment:
                encode = encode || "\"<>`".contains(character)
            case .query:
                encode = encode || "\"#<>".contains(character)
            case .specialQuery:
                encode = encode || "\"#<>'".contains(character)
            case .path:
                encode = encode || "\"#<>?`{}".contains(character)
            case .userinfo:
                encode = encode || "\"#<>?`{}/:;=@[\\]^|".contains(character)
            }
            if encode {
                output += String(format: "%%%02X", byte)
            } else {
                output.append(character)
            }
        }
        return output
    }

    public func queryParameter(_ name: String) -> String? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = WebURL.formDecode(String(pieces[0]))
            if key == name { return pieces.count > 1 ? WebURL.formDecode(String(pieces[1])) : "" }
        }
        return nil
    }

    static func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

public func decodeURIComponent(_ value: String) -> String {
    value.removingPercentEncoding ?? value
}
