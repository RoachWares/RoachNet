import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPClientResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public var ok: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    public static func request(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 5_000,
        maxResponseBytes: Int? = nil
    ) throws -> HTTPClientResponse {
        guard let url = URL(string: urlString) else {
            throw RuntimeError("Invalid URL: \(WebURL(urlString)?.redacted ?? "unreadable")")
        }
        guard url.user == nil, url.password == nil else {
            throw RuntimeError("RoachNet doesn't send requests to an address that carries a user name or password.")
        }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(timeoutMs) / 1000)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = body }

        let semaphore = DispatchSemaphore(value: 0)
        let outcome = LockedBox<(data: Data?, response: URLResponse?, error: Error?)>((nil, nil, nil))
        let collector = maxResponseBytes.map {
            BoundedResponseCollector(limit: $0) { data, response, error in
                outcome.value = (data, response, error)
                semaphore.signal()
            }
        }
        let boundedSession = collector.map {
            URLSession(configuration: session.configuration, delegate: $0, delegateQueue: nil)
        }
        defer { boundedSession?.finishTasksAndInvalidate() }
        let task: URLSessionDataTask
        if let boundedSession {
            task = boundedSession.dataTask(with: request)
        } else {
            task = session.dataTask(with: request) { data, response, error in
                outcome.value = (data, response, error)
                semaphore.signal()
            }
        }
        task.resume()
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs + 250)
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
            throw RuntimeError("The operation was aborted due to timeout")
        }
        if let maxResponseBytes, collector?.exceeded == true {
            throw RuntimeError("Response from \(WebURL.display(urlString)) exceeded \(maxResponseBytes) bytes.")
        }
        let (resultData, resultResponse, resultError) = outcome.value
        if let resultError {
            if (resultError as NSError).code == NSURLErrorTimedOut {
                throw RuntimeError("The operation was aborted due to timeout")
            }
            throw RuntimeError(resultError.localizedDescription)
        }
        guard let http = resultResponse as? HTTPURLResponse else {
            throw RuntimeError("No HTTP response from \(WebURL.display(urlString))")
        }
        let data = resultData ?? Data()
        if let maxResponseBytes, data.count > maxResponseBytes {
            throw RuntimeError("Response from \(WebURL.display(urlString)) exceeded \(maxResponseBytes) bytes.")
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headerMap[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPClientResponse(status: http.statusCode, headers: headerMap, body: data)
    }

    public static func fetchJSON(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 5_000
    ) throws -> JSON {
        var merged = [
            "content-type": "application/json",
            "user-agent": "RoachNet/\(RuntimeConfiguration.shared.version) native-api",
        ]
        for (key, value) in headers { merged[key] = value }
        let response = try request(url, method: method, headers: merged, body: body, timeoutMs: timeoutMs)
        let text = response.text
        let data: JSON = text.isEmpty ? .object(JSONObject()) : try JSON.parse(text)
        if !response.ok {
            let message =
                (data["error"] || data["message"]).truthy
                ? (data["error"] || data["message"]).jsString
                : "\(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))"
            throw RuntimeError(message)
        }
        return data
    }
}

final class BoundedResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var tooLarge = false
    private let finish: (Data?, URLResponse?, Error?) -> Void

    init(limit: Int, finish: @escaping (Data?, URLResponse?, Error?) -> Void) {
        self.limit = max(0, limit)
        self.finish = finish
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tooLarge
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        let announcedTooLarge = response.expectedContentLength > Int64(limit)
        if announcedTooLarge { tooLarge = true }
        lock.unlock()
        completionHandler(announcedTooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        if tooLarge || data.count + chunk.count > limit {
            tooLarge = true
            lock.unlock()
            dataTask.cancel()
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = data
        let received = response
        lock.unlock()
        finish(body, received, error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        RedirectGuard.decide(task, response, request, completionHandler)
    }
}

public final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Progress {
        public var expectedBytes: Int64?
        public var receivedBytes: Int64
    }

    private let url: URL
    private let headers: [String: String]
    private let maxBytes: Int64
    private let resumeFrom: Int64
    private let onResponse: ((Bool) throws -> Void)?
    private let onChunk: (Data, Progress) throws -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var failure: Error?
    private var statusCode = 0
    private var expected: Int64?
    private var received: Int64 = 0
    private let lock = NSLock()
    private var cancelled = false
    private var stallSeconds = 0

    public init(
        url: URL, headers: [String: String], maxBytes: Int64, resumeFrom: Int64 = 0,
        onResponse: ((Bool) throws -> Void)? = nil, onChunk: @escaping (Data, Progress) throws -> Void
    ) {
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
        self.resumeFrom = max(0, resumeFrom)
        self.onResponse = onResponse
        self.onChunk = onChunk
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel()
    }

    public func run(timeoutMs: Int) throws -> (received: Int64, expected: Int64?) {
        try run(stallTimeoutMs: timeoutMs, totalTimeoutMs: timeoutMs)
    }

    public func run(stallTimeoutMs: Int, totalTimeoutMs: Int) throws -> (received: Int64, expected: Int64?) {
        guard url.user == nil, url.password == nil else {
            throw RuntimeError(
                "RoachNet doesn't send requests to an address that carries a user name or password.", statusCode: 400)
        }
        let stall = max(1, min(stallTimeoutMs, totalTimeoutMs))
        stallSeconds = max(1, stall / 1000)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Double(stall) / 1000
        configuration.timeoutIntervalForResource = Double(totalTimeoutMs) / 1000
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(stall) / 1000)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(totalTimeoutMs) + .seconds(15))
        session.invalidateAndCancel()
        if waitResult == .timedOut {
            task.cancel()
            throw RuntimeError("The operation was aborted due to timeout", statusCode: 504)
        }
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw RuntimeError("This operation was aborted", statusCode: 499) }
        if let failure { throw failure }
        if !(200..<300).contains(statusCode) {
            throw RuntimeError(
                "HTTP \(statusCode) while downloading \(WebURL.display(url.absoluteString))",
                statusCode: statusCode == 0 ? 502 : statusCode)
        }
        if let expected, expected > 0, received != expected {
            throw RuntimeError("Download ended early after \(received) of \(expected) bytes.", statusCode: 503)
        }
        return (received, expected)
    }

    static func parseContentRange(_ value: String?) -> (start: Int64, total: Int64?)? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst(6)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard halves.count == 2, let dash = halves[0].firstIndex(of: "-"),
            let start = Int64(halves[0][halves[0].startIndex..<dash])
        else { return nil }
        return (start, Int64(halves[1]))
    }

    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = http.statusCode
        if !(200..<300).contains(statusCode) {
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        var restart = false
        if resumeFrom > 0 && statusCode == 206 {
            guard let range = StreamingDownload.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                range.start == resumeFrom
            else {
                failure = RuntimeError(
                    "The server resumed \(WebURL.display(url.absoluteString)) at the wrong offset.", statusCode: 502)
                completionHandler(.cancel)
                return
            }
            received = resumeFrom
            expected = range.total ?? length.map { $0 + resumeFrom }
        } else {
            restart = resumeFrom > 0
            received = 0
            expected = length
        }
        if let expected, expected > maxBytes {
            failure = RuntimeError("Download is larger than the configured \(maxBytes) byte limit.", statusCode: 413)
            completionHandler(.cancel)
            return
        }
        do {
            try onResponse?(restart)
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if failure != nil { return }
        received += Int64(data.count)
        if received > maxBytes {
            failure = RuntimeError("Download exceeded the configured \(maxBytes) byte limit.", statusCode: 413)
            dataTask.cancel()
            return
        }
        do {
            try onChunk(data, Progress(expectedBytes: expected, receivedBytes: received))
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil, (200..<300).contains(statusCode) || statusCode == 0 {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    failure = RuntimeError(
                        "No data arrived for \(stallSeconds)s; the connection stalled.", statusCode: 504)
                case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable, .dataNotAllowed,
                    .internationalRoamingOff:
                    failure = RuntimeError(urlError.localizedDescription, statusCode: 503)
                case .cancelled:
                    failure = RuntimeError(urlError.localizedDescription, statusCode: 499)
                default:
                    failure = RuntimeError(urlError.localizedDescription, statusCode: 520)
                }
            } else {
                failure = RuntimeError(error.localizedDescription, statusCode: 520)
            }
        }
        semaphore.signal()
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let reason = RedirectGuard.decide(task, response, request, completionHandler), failure == nil {
            failure = RuntimeError("The download was redirected to \(reason).", statusCode: 403)
        }
    }
}

public enum DNS {
    public static func resolves(_ host: String, timeoutMs: Int = 3_000) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let ok = LockedBox(false)
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if status == 0 { ok.value = true }
            if let result { freeaddrinfo(result) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut { return false }
        return ok.value
    }

    public static func addresses(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
        defer { if let result { freeaddrinfo(result) } }
        var addresses: [String] = []
        var cursor = result
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if entry.pointee.ai_family == AF_INET {
                entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var address = pointer.pointee.sin_addr
                    inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
                }
                addresses.append(String(cString: buffer))
            } else if entry.pointee.ai_family == AF_INET6 {
                entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    var address = pointer.pointee.sin6_addr
                    inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
                }
                addresses.append(String(cString: buffer))
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}
