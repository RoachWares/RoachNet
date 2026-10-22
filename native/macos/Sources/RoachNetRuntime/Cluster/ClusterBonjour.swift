#if canImport(dnssd) && canImport(CryptoKit) && canImport(Metal)
import dnssd
import Foundation

final class ClusterBonjour {
    static let serviceType = "_roachnet-cluster._tcp"
    private var registration: DNSServiceRef?

    struct Found: Equatable {
        var name: String
        var host: String
        var port: UInt16
        var id: String
        var fingerprint: String
        var address: String { "\(host.hasSuffix(".") ? String(host.dropLast()) : host):\(port)" }
    }

    static func txt(_ entries: [String: String]) -> Data {
        var data = Data()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = Array("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    static func parseTXT(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            let start = data.index(after: index)
            guard let end = data.index(start, offsetBy: length, limitedBy: data.endIndex) else { break }
            let entry = String(decoding: data[start..<end], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                out[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index = end
        }
        return out
    }

    func advertise(name: String, port: UInt16, id: String, fingerprint: String) {
        stop()
        let record = ClusterBonjour.txt(["id": id, "fp": fingerprint])
        var ref: DNSServiceRef?
        let status = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, name, ClusterBonjour.serviceType, nil, nil, port.bigEndian, UInt16(bytes.count),
                bytes.baseAddress, nil, nil)
        }
        if status == kDNSServiceErr_NoError {
            registration = ref
        } else {
            RuntimeLog.write("cluster: Bonjour advertising failed (\(status))")
        }
    }

    func stop() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
    }

    deinit { stop() }

    static func browse(seconds: Double = 1.5) -> [Found] {
        final class Box {
            var names: [(String, String, UInt32)] = []
            var found: [Found] = []
            var pendingName = ""
        }
        let box = Box()
        let context = Unmanaged.passUnretained(box).toOpaque()
        var browser: DNSServiceRef?
        let browseReply: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name,
                let domain, let context
            else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            box.names.append((String(cString: name), String(cString: domain), interface))
        }
        guard DNSServiceBrowse(&browser, 0, 0, serviceType, nil, browseReply, context) == kDNSServiceErr_NoError,
            let browser
        else { return [] }
        defer { DNSServiceRefDeallocate(browser) }
        pump(browser, seconds: seconds)

        let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, port, length, txt, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            let record = txt.map { ClusterBonjour.parseTXT(Data(bytes: $0, count: Int(length))) } ?? [:]
            box.found.append(
                Found(
                    name: box.pendingName, host: String(cString: host), port: UInt16(bigEndian: port),
                    id: record["id"] ?? "", fingerprint: record["fp"] ?? ""))
        }
        for (name, domain, interface) in box.names where !box.found.contains(where: { $0.name == name }) {
            var resolver: DNSServiceRef?
            box.pendingName = name
            guard
                DNSServiceResolve(&resolver, 0, interface, name, serviceType, domain, resolveReply, context)
                    == kDNSServiceErr_NoError,
                let resolver
            else { continue }
            pump(resolver, seconds: 1)
            DNSServiceRefDeallocate(resolver)
        }
        return box.found
    }

    private static func pump(_ ref: DNSServiceRef, seconds: Double) {
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
            guard poll(&poller, 1, wait) == 1 else { break }
            guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { break }
        }
    }
}
#endif
