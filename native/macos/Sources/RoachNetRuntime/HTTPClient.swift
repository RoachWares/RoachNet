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

/// Synchronous wrappers over the system URL loading stack.
public enum HTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration)
    }()

    public static func request(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 5_000,
        maxResponseBytes: Int? = nil
    ) throws -> HTTPClientResponse {
        guard let url = URL(string: urlString) else { throw RuntimeError("Invalid URL: \(urlString)") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(timeoutMs) / 1000)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = body }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs + 250)
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
            throw RuntimeError("The operation was aborted due to timeout")
        }
        if let resultError {
            if (resultError as NSError).code == NSURLErrorTimedOut {
                throw RuntimeError("The operation was aborted due to timeout")
            }
            throw RuntimeError(resultError.localizedDescription)
        }
        guard let http = resultResponse as? HTTPURLResponse else { throw RuntimeError("No HTTP response from \(urlString)") }
        let data = resultData ?? Data()
        if let maxResponseBytes, data.count > maxResponseBytes {
            throw RuntimeError("Response from \(urlString) exceeded \(maxResponseBytes) bytes.")
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headerMap[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPClientResponse(status: http.statusCode, headers: headerMap, body: data)
    }

    /// `fetchJson(url, options)`: parses the body and throws on non-2xx.
    public static func fetchJSON(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 5_000
    ) throws -> JSON {
        var merged = ["content-type": "application/json", "user-agent": "RoachNet/\(RuntimeConfiguration.shared.version) native-api"]
        for (key, value) in headers { merged[key] = value }
        let response = try request(url, method: method, headers: merged, body: body, timeoutMs: timeoutMs)
        let text = response.text
        let data: JSON = text.isEmpty ? .object(JSONObject()) : try JSON.parse(text)
        if !response.ok {
            let message = (data["error"] || data["message"]).truthy
                ? (data["error"] || data["message"]).jsString
                : "\(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))"
            throw RuntimeError(message)
        }
        return data
    }
}

/// Streams one HTTP response into a file handle with byte-ceiling checks.
public final class StreamingDownload: NSObject, URLSessionDataDelegate {
    public struct Progress {
        public var expectedBytes: Int64?
        public var receivedBytes: Int64
    }

    private let url: URL
    private let headers: [String: String]
    private let maxBytes: Int64
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

    public init(url: URL, headers: [String: String], maxBytes: Int64, onChunk: @escaping (Data, Progress) throws -> Void) {
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
        self.onChunk = onChunk
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel()
    }

    /// Runs the transfer; returns the number of bytes received.
    public func run(timeoutMs: Int) throws -> (received: Int64, expected: Int64?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Double(timeoutMs) / 1000
        configuration.timeoutIntervalForResource = Double(timeoutMs) / 1000
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(timeoutMs) / 1000)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
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
            throw RuntimeError("HTTP \(statusCode) while downloading \(url.absoluteString)")
        }
        if let expected, expected > 0, received != expected {
            throw RuntimeError("Download ended early after \(received) of \(expected) bytes.")
        }
        return (received, expected)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = http.statusCode
        if !(200..<300).contains(statusCode) {
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength
        expected = length > 0 ? length : nil
        if let expected, expected > maxBytes {
            failure = RuntimeError("Download is larger than the configured \(maxBytes) byte limit.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if failure != nil { return }
        received += Int64(data.count)
        if received > maxBytes {
            failure = RuntimeError("Download exceeded the configured \(maxBytes) byte limit.")
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
            failure = RuntimeError(error.localizedDescription)
        }
        semaphore.signal()
    }
}

/// `dns.lookup(host)` reachability probe.
public enum DNS {
    public static func resolves(_ host: String, timeoutMs: Int = 3_000) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if status == 0 { ok = true }
            if let result { freeaddrinfo(result) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut { return false }
        return ok
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
