import Foundation

final class DownloadJob {
    let jobId = JS.randomUUID()
    let url: String
    var progress: Double = 0
    let filepath: String
    var partialFilepath: String { "\(filepath).part" }
    let filetype: String
    var status = "queued"
    var failedReason: String?
    let descriptorUrl: String?
    let expectedSha256: String?
    let parts: [JSON]
    var totalBytes: Int64?
    var bytesReceived: Int64 = 0
    let createdAt = JS.isoNow()
    var updatedAt = JS.isoNow()
    var completedAt: String?
    var installPath: String?
    var installStatus: String?
    var sha256: String?
    var afterDownload: ((DownloadJob) throws -> Void)?
    var activeTransfer: StreamingDownload?
    var attempts = 0
    var resumedFrom: Int64?
    var lastError: String?
    var partialKept = false
    var resumable: Bool { filetype != "dmg" }

    init(
        url: String, filepath: String, filetype: String, descriptorUrl: String?, expectedSha256: String?, parts: [JSON]
    ) {
        self.url = url
        self.filepath = filepath
        self.filetype = filetype
        self.descriptorUrl = descriptorUrl
        self.expectedSha256 = expectedSha256
        self.parts = parts
    }

    var json: JSON {
        var object: JSON = [
            "jobId": JSON(jobId),
            "url": JSON(url),
            "progress": JSON(progress),
            "filepath": JSON(filepath),
            "partialFilepath": JSON(partialFilepath),
            "filetype": JSON(filetype),
            "status": JSON(status),
            "failedReason": JSON(failedReason),
            "descriptorUrl": JSON(descriptorUrl),
            "expectedSha256": JSON(expectedSha256),
            "parts": .array(parts),
            "totalBytes": totalBytes.map { JSON(Double($0)) } ?? .null,
            "bytesReceived": JSON(Double(bytesReceived)),
            "createdAt": JSON(createdAt),
            "updatedAt": JSON(updatedAt),
            "completedAt": JSON(completedAt),
            "installPath": JSON(installPath),
            "installStatus": JSON(installStatus),
            "attempts": JSON(attempts),
            "resumedFrom": resumedFrom.map { JSON(Double($0)) } ?? .null,
            "lastError": JSON(lastError),
            "partialKept": JSON(partialKept),
        ]
        if let sha256 { object["sha256"] = JSON(sha256) }
        return object
    }
}

extension NativeRuntime {
    func downloadJobsSnapshot() -> [JSON] { withState { downloadJobs.map(\.json) } }

    func parseDownloadUrl(_ raw: JSON) -> String? {
        guard let parsed = WebURL((raw.isNullish ? "" : raw.jsString).trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(parsed.scheme)
        else { return nil }
        return parsed.description
    }

    func isAppsDownloadDescriptorUrl(_ raw: String) -> Bool {
        guard let parsed = WebURL(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(parsed.scheme), parsed.pathname.hasSuffix(".json"),
            let base = WebURL(config.appsDownloadsBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https"].contains(base.scheme)
        else { return false }
        let prefix = JS.replace("/+$", in: base.pathname, with: "") + "/"
        return parsed.origin == base.origin && parsed.pathname.hasPrefix(prefix)
    }

    private static let unusableSourcePattern = "(pending|required|blocked|failed)"

    func pickDescriptorSource(_ descriptor: JSON) -> String? {
        for source in descriptor["sources"].array {
            let status = (source["status"] || "").jsString
            if source["type"].stringValue == "internet-archive-parts"
                || JS.matches(NativeRuntime.unusableSourcePattern, status, caseInsensitive: true)
            {
                continue
            }
            if let candidate = parseDownloadUrl(source["url"]) { return candidate }
        }
        return parseDownloadUrl(descriptor["url"] || descriptor["downloadUrl"] || descriptor["archiveUrl"])
    }

    func descriptorPartsAreUsable(_ descriptor: JSON) -> Bool {
        descriptor["sources"].array.contains { source in
            guard source["type"].stringValue == "internet-archive-parts" else { return false }
            let status = (source["status"] || "").jsString
            return !status.isEmpty && !JS.matches(NativeRuntime.unusableSourcePattern, status, caseInsensitive: true)
        }
    }

    func descriptorParts(_ descriptor: JSON) -> [JSON] {
        guard descriptorPartsAreUsable(descriptor) else { return [] }
        var normalized: [JSON] = []
        for part in descriptor["parts"].array {
            let bytes = part["bytes"].jsNumber
            let offset = part["offset"].jsNumber
            let sha = (part["sha256"] || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let url = parseDownloadUrl(part["url"]), JSCoercion.isSafeInteger(bytes), bytes > 0 else { return [] }
            normalized.append([
                "index": JS.isSafeInteger(part["index"]) ? JSON(part["index"].jsNumber) : JSON(normalized.count),
                "url": JSON(url),
                "bytes": JSON(bytes),
                "encodedBytes": JS.isSafeInteger(part["encodedBytes"]) ? JSON(part["encodedBytes"].jsNumber) : nil,
                "offset": JSCoercion.isSafeInteger(offset) && offset >= 0 ? JSON(offset) : nil,
                "sha256": JS.matches("^[a-f0-9]{64}$", sha) ? JSON(sha) : nil,
                "encoding": part["encoding"] || nil,
                "header": part["header"].stringValue.map { JSON($0) } ?? .null,
            ])
        }
        return normalized.sorted { $0["index"].jsNumber < $1["index"].jsNumber }
    }

    func resolveDownloadDescriptor(_ rawUrl: JSON) throws -> (
        url: String?, descriptorUrl: String?, sha256: String?, filename: String?, parts: [JSON]
    ) {
        guard let descriptorUrl = parseDownloadUrl(rawUrl), isAppsDownloadDescriptorUrl(descriptorUrl) else {
            return (parseDownloadUrl(rawUrl), nil, nil, nil, [])
        }
        let response = try HTTPClient.request(
            descriptorUrl,
            headers: [
                "accept": "application/json",
                "user-agent": "RoachNet/\(version) descriptor-resolver",
            ], timeoutMs: 30_000, maxResponseBytes: 2 * 1024 * 1024)
        if !response.ok { throw RuntimeError("HTTP \(response.status) while resolving \(descriptorUrl)") }
        let descriptor = try JSON.parse(response.body)
        let resolved = pickDescriptorSource(descriptor)
        let parts = descriptorParts(descriptor)
        if resolved == nil && parts.isEmpty {
            throw RuntimeError("Download descriptor has no usable HTTP source: \(descriptorUrl)")
        }
        let sha = (descriptor["sha256"] || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (
            parts.isEmpty ? resolved : descriptorUrl,
            descriptorUrl,
            JS.matches("^[a-f0-9]{64}$", sha) ? sha : nil,
            descriptor["filename"].truthy ? descriptor["filename"].jsString : nil,
            parts
        )
    }

    @discardableResult
    func queueDownload(
        _ rawUrl: String, _ destinationDirectory: String, _ filetype: String,
        filename: String? = nil, descriptorUrl: String? = nil, expectedSha256: String? = nil,
        parts: [JSON] = [], afterDownload: ((DownloadJob) throws -> Void)? = nil
    ) throws -> DownloadJob? {
        guard let url = parseDownloadUrl(JSON(rawUrl)) else { return nil }
        try? Files.mkdirp(destinationDirectory)
        let fallbackName = "\(JS.randomUUID()).\(filetype.isEmpty ? "download" : filetype)"
        var chosen = safeFileName(JSON(filename ?? fileNameForUrl(JSON(url), fallbackName)), fallbackName)
        if Path.basename(Path.join(destinationDirectory, chosen)) != chosen { chosen = fallbackName }
        let lowered = chosen.lowercased()
        if lowered.hasSuffix(".part") || lowered.hasSuffix(".part.json") { chosen = fallbackName }
        let filepath = Path.join(destinationDirectory, chosen)
        return try withState { () throws -> DownloadJob in
            if let writer = downloadWriters[downloadPathKey(filepath)] {
                if writer.url == url, writer.filepath.unicodeScalars.elementsEqual(filepath.unicodeScalars),
                    Self.activeDownloadStatuses.contains(writer.status)
                {
                    return writer
                }
                throw requestError("A download to \(Path.basename(filepath)) is already running.", 409)
            }
            let job = DownloadJob(
                url: url, filepath: filepath, filetype: filetype, descriptorUrl: descriptorUrl,
                expectedSha256: expectedSha256, parts: parts)
            job.afterDownload = afterDownload
            downloadWriters[downloadPathKey(filepath)] = job
            downloadJobs = Self.trimmedDownloadJobs([job] + downloadJobs)
            DispatchQueue.global(qos: .utility).async {
                defer { self.releaseDownloadWriter(job) }
                do {
                    try self.downloadFile(job)
                } catch {
                    self.withState {
                        job.status = "failed"
                        job.failedReason = "\(error)"
                        job.progress = 0
                    }
                    self.log("download failed \(job.jobId): \(error)")
                }
            }
            return job
        }
    }

    func downloadNow(_ rawUrl: JSON, to filepath: String, filetype: String, expectedSha256: String?) throws {
        let resolved = try resolveDownloadDescriptor(rawUrl)
        guard let url = resolved.url else { throw RuntimeError("No usable download URL in \(rawUrl.jsString).") }
        if let expectedSha256, let descriptorSha = resolved.sha256, expectedSha256.lowercased() != descriptorSha {
            throw RuntimeError("The download descriptor's checksum does not match the pack manifest.")
        }
        try Files.mkdirp(Path.dirname(filepath))
        let job = DownloadJob(
            url: url, filepath: filepath, filetype: filetype, descriptorUrl: resolved.descriptorUrl,
            expectedSha256: expectedSha256?.lowercased() ?? resolved.sha256, parts: resolved.parts)
        try withState { () throws in
            if downloadWriters[downloadPathKey(filepath)] != nil {
                throw requestError("A download to \(Path.basename(filepath)) is already running.", 409)
            }
            downloadWriters[downloadPathKey(filepath)] = job
            downloadJobs = Self.trimmedDownloadJobs([job] + downloadJobs)
        }
        defer { releaseDownloadWriter(job) }
        do {
            try downloadFile(job)
        } catch {
            withState {
                job.status = "failed"
                job.failedReason = "\(error)"
                job.progress = 0
            }
            throw error
        }
        if withState({ job.status }) != "completed" {
            throw RuntimeError("The download of \(Path.basename(filepath)) was cancelled.", statusCode: 499)
        }
    }

    static let activeDownloadStatuses: Set<String> = ["queued", "downloading", "installing"]

    func downloadPathKey(_ filepath: String) -> String {
        let normalized = Path.normalize(filepath)
        #if canImport(Darwin)
        return normalized.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        #else
        return normalized
        #endif
    }

    func releaseDownloadWriter(_ job: DownloadJob) {
        withState {
            let key = downloadPathKey(job.filepath)
            if downloadWriters[key] === job { downloadWriters[key] = nil }
        }
    }

    static func trimmedDownloadJobs(_ jobs: [DownloadJob], keeping limit: Int = 200) -> [DownloadJob] {
        var finished = 0
        return jobs.filter { job in
            if activeDownloadStatuses.contains(job.status) { return true }
            finished += 1
            return finished <= limit
        }
    }

    func queueResolvedDownload(
        _ rawUrl: JSON, _ destinationDirectory: String, _ filetype: String,
        expectedSha256: String? = nil,
        afterDownload: ((DownloadJob) throws -> Void)? = nil
    ) throws -> DownloadJob? {
        let pinned = expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let pinned, !JS.matches("^[a-f0-9]{64}$", pinned) {
            throw requestError("The expected checksum is not a SHA-256.", 422)
        }
        let resolved = try resolveDownloadDescriptor(rawUrl)
        guard let url = resolved.url else { return nil }
        if let pinned, let descriptorSha = resolved.sha256, pinned != descriptorSha {
            throw requestError("The download descriptor's checksum does not match the catalog.", 422)
        }
        return try queueDownload(
            url, destinationDirectory, filetype, filename: resolved.filename, descriptorUrl: resolved.descriptorUrl,
            expectedSha256: pinned ?? resolved.sha256, parts: resolved.parts, afterDownload: afterDownload)
    }

    private func updateProgress(_ job: DownloadJob, received: Int64, total: Int64?) {
        withState {
            job.bytesReceived = received
            job.updatedAt = JS.isoNow()
            if let total, total > 0 {
                job.progress = max(1, min(99, JS.round(Double(received) / Double(total) * 100)))
            }
        }
    }

    func resumeMarkerPath(_ job: DownloadJob) -> String { "\(job.partialFilepath).json" }

    func partialIsResumable(_ job: DownloadJob) -> Bool {
        guard job.resumable, job.parts.isEmpty, Files.isRegularFile(job.partialFilepath),
            let text = Files.readText(resumeMarkerPath(job)), let marker = try? JSON.parse(text)
        else { return false }
        return marker["url"].stringValue == job.url && marker["sha256"].stringValue == job.expectedSha256
    }

    func writeResumeMarker(_ job: DownloadJob) {
        let marker: JSON = ["url": JSON(job.url), "sha256": JSON(job.expectedSha256), "startedAt": JSON(job.createdAt)]
        try? Files.writePrettyJSON(marker, to: resumeMarkerPath(job))
    }

    func isTransientDownloadError(_ error: Error) -> Bool {
        guard let runtimeError = error as? RuntimeError else { return false }
        switch runtimeError.statusCode {
        case 408, 425, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }

    func fileSize(_ path: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    func streamWithResume(_ job: DownloadJob, _ handle: FileHandle, deadline: Date) throws {
        guard let url = URL(string: job.url) else { throw RuntimeError("Invalid URL: \(job.url)", statusCode: 400) }
        let maxBytes = Int64(config.maxDownloadBytes)
        var attempt = 0
        var restartedAfter416 = false
        while true {
            attempt += 1
            let offset = Int64(try handle.seekToEnd())
            let transfer = StreamingDownload(
                url: url,
                headers: ["user-agent": "RoachNet/\(version) native-downloader"],
                maxBytes: maxBytes,
                resumeFrom: offset,
                onResponse: { restart in
                    if restart {
                        try handle.truncate(atOffset: 0)
                        try handle.seek(toOffset: 0)
                    }
                },
                onChunk: { [weak self] data, progress in
                    try handle.write(contentsOf: data)
                    self?.updateProgress(job, received: progress.receivedBytes, total: progress.expectedBytes)
                    if progress.expectedBytes != nil { self?.withState { job.totalBytes = progress.expectedBytes } }
                }
            )
            let cancelled = withState { () -> Bool in
                job.activeTransfer = transfer
                job.attempts = attempt
                job.resumedFrom = offset > 0 ? offset : job.resumedFrom
                return job.status == "cancelled"
            }
            if cancelled {
                withState { job.activeTransfer = nil }
                throw RuntimeError("This operation was aborted", statusCode: 499)
            }
            let remaining = Int(deadline.timeIntervalSinceNow * 1000)
            if remaining <= 0 { throw RuntimeError("The operation was aborted due to timeout", statusCode: 504) }
            do {
                _ = try transfer.run(stallTimeoutMs: config.downloadStallTimeoutMs, totalTimeoutMs: remaining)
                withState { job.activeTransfer = nil }
                return
            } catch {
                withState { job.activeTransfer = nil }
                if withState({ job.status }) == "cancelled" {
                    throw RuntimeError("This operation was aborted", statusCode: 499)
                }
                if let runtimeError = error as? RuntimeError, runtimeError.statusCode == 416, !restartedAfter416 {
                    restartedAfter416 = true
                    try handle.truncate(atOffset: 0)
                    continue
                }
                guard job.resumable, isTransientDownloadError(error), attempt < config.downloadMaxAttempts else {
                    throw error
                }
                let pause = min(30.0, pow(2.0, Double(attempt)))
                log("download \(job.jobId) attempt \(attempt) failed (\(error)); resuming in \(Int(pause))s")
                withState {
                    job.lastError = "\(error)"
                    job.updatedAt = JS.isoNow()
                }
                let wakeAt = Date().addingTimeInterval(pause)
                while Date() < wakeAt {
                    if withState({ job.status }) == "cancelled" {
                        throw RuntimeError("This operation was aborted", statusCode: 499)
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }
    }

    func downloadFile(_ job: DownloadJob) throws {
        let started = withState { () -> Bool in
            guard job.status != "cancelled" else { return false }
            job.status = "downloading"
            return true
        }
        guard started else { return }
        let deadline = Date().addingTimeInterval(Double(config.downloadTimeoutMs) / 1000)
        let resuming = partialIsResumable(job)
        if !resuming {
            Files.removeFile(job.partialFilepath)
            Files.removeFile(resumeMarkerPath(job))
        }
        withState { job.updatedAt = JS.isoNow() }
        let descriptor = try openPartialFile(job, resuming: resuming)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        if job.parts.isEmpty && job.resumable { writeResumeMarker(job) }
        var handleOpen = true
        func closeHandle() {
            if handleOpen {
                try? handle.close()
                handleOpen = false
            }
        }
        var placed = false

        do {
            if !job.parts.isEmpty {
                try downloadChunkedFile(job, handle, deadline: deadline)
            } else {
                try streamWithResume(job, handle, deadline: deadline)
            }
            closeHandle()
            if withState({ job.status }) == "cancelled" {
                throw RuntimeError("This operation was aborted", statusCode: 499)
            }
            if let expected = job.expectedSha256 {
                let actual = try SHA256Digest.hexOfFile(atPath: job.partialFilepath)
                if actual != expected {
                    throw RuntimeError(
                        "Checksum mismatch for \(job.url). Expected \(expected), found \(actual).", statusCode: 422)
                }
                withState { job.sha256 = actual }
            }
            let committing = withState { () -> Bool in
                guard job.status != "cancelled" else { return false }
                job.status = "installing"
                job.updatedAt = JS.isoNow()
                return true
            }
            guard committing else { throw RuntimeError("This operation was aborted", statusCode: 499) }
            try Files.rename(job.partialFilepath, job.filepath)
            placed = true
            Files.removeFile(resumeMarkerPath(job))
            if let afterDownload = job.afterDownload {
                withState {
                    job.status = "installing"
                    job.installStatus = "installing"
                    job.progress = 99
                    job.updatedAt = JS.isoNow()
                }
                try afterDownload(job)
            }
            withState {
                job.progress = 100
                job.status = "completed"
                job.installStatus = job.installStatus ?? "downloaded"
                job.completedAt = JS.isoNow()
                job.updatedAt = job.completedAt!
            }
        } catch {
            closeHandle()
            let wasCancelled = withState { job.status == "cancelled" }
            let keepPartial =
                !wasCancelled && job.resumable && job.parts.isEmpty && isTransientDownloadError(error)
                && fileSize(job.partialFilepath) > 0
            if !keepPartial {
                Files.removeFile(job.partialFilepath)
                Files.removeFile(resumeMarkerPath(job))
            }
            if placed { Files.removeFile(job.filepath) }
            withState {
                job.activeTransfer = nil
                job.updatedAt = JS.isoNow()
                job.partialKept = keepPartial
                if wasCancelled {
                    job.progress = 0
                    job.completedAt = job.updatedAt
                }
            }
            if wasCancelled { return }
            var message: String
            if let runtimeError = error as? RuntimeError, runtimeError.statusCode == 504 {
                message = "Download from \(job.url) timed out: \(runtimeError.message)"
            } else {
                message = "Download from \(job.url) failed: \(error)"
            }
            if keepPartial {
                message +=
                    " \(fileSize(job.partialFilepath)) bytes are kept; install it again to pick up where it stopped."
            }
            throw RuntimeError(message)
        }
    }

    func openPartialFile(_ job: DownloadJob, resuming: Bool) throws -> Int32 {
        if resuming {
            let descriptor = open(job.partialFilepath, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 {
                var info = stat()
                if fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 {
                    return descriptor
                }
                close(descriptor)
            }
            log("download \(job.jobId): the partial file can't be resumed safely; starting over")
        }
        for _ in 0..<3 {
            Files.removeFile(job.partialFilepath)
            let descriptor = open(job.partialFilepath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if descriptor >= 0 { return descriptor }
            if errno != EEXIST { break }
        }
        throw RuntimeError(
            "Download from \(job.url) failed: unable to create \(job.partialFilepath): \(String(cString: strerror(errno)))"
        )
    }

    func decodeChunkPayload(_ part: JSON, _ body: Data) throws -> Data {
        guard part["encoding"].stringValue == "roachnet-ia-chunk-v1" else { return body }
        let header = Data((part["header"] || "").jsString.utf8)
        let index = Int(part["index"].jsNumber) + 1
        guard !header.isEmpty, body.count >= header.count, body.prefix(header.count) == header else {
            throw RuntimeError("Chunk \(index) did not contain the expected RoachNet IA envelope.")
        }
        return body.subdata(in: header.count..<body.count)
    }

    func downloadChunkedFile(_ job: DownloadJob, _ handle: FileHandle, deadline: Date) throws {
        let total = job.parts.reduce(0.0) { $0 + ($1["bytes"] || 0).jsNumber }
        withState { job.totalBytes = total > 0 ? Int64(total) : nil }
        if total > Double(config.maxDownloadBytes) {
            throw RuntimeError("Download is larger than the configured \(config.maxDownloadBytes) byte limit.")
        }
        var received: Int64 = 0
        for part in job.parts {
            if withState({ job.status }) == "cancelled" {
                throw RuntimeError("This operation was aborted", statusCode: 499)
            }
            let index = Int(part["index"].jsNumber) + 1
            let expectedTransfer = Int((part["encodedBytes"] || part["bytes"]).jsNumber)
            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            let response = try HTTPClient.request(
                part["url"].jsString, headers: ["user-agent": "RoachNet/\(version) native-downloader chunked"],
                timeoutMs: remaining)
            if !response.ok { throw RuntimeError("HTTP \(response.status) while downloading \(part["url"].jsString)") }
            if let length = Int(response.headers["content-length"] ?? ""), length > 0, length != expectedTransfer {
                throw RuntimeError("Chunk \(index) reported \(length) bytes, expected \(expectedTransfer).")
            }
            if response.body.count != expectedTransfer {
                throw RuntimeError(
                    "Chunk \(index) ended early after \(response.body.count) of \(expectedTransfer) bytes.")
            }
            let payload = try decodeChunkPayload(part, response.body)
            if payload.count != Int(part["bytes"].jsNumber) {
                throw RuntimeError(
                    "Chunk \(index) decoded to \(payload.count) bytes, expected \(Int(part["bytes"].jsNumber)).")
            }
            let actual = SHA256Digest.hex(payload)
            if let expected = part["sha256"].stringValue, actual != expected {
                throw RuntimeError(
                    "Chunk checksum mismatch for \(part["url"].jsString). Expected \(expected), found \(actual).")
            }
            received += Int64(payload.count)
            if received > Int64(config.maxDownloadBytes) {
                throw RuntimeError("Download exceeded the configured \(config.maxDownloadBytes) byte limit.")
            }
            updateProgress(job, received: received, total: total > 0 ? Int64(total) : nil)
            handle.write(payload)
        }
        if total > 0 && Double(received) != total {
            throw RuntimeError("Chunked download ended early after \(received) of \(Int64(total)) bytes.")
        }
    }

    func cancelDownloadJob(_ jobId: String) -> Bool {
        withState {
            guard let job = downloadJobs.first(where: { $0.jobId == jobId }) else { return false }
            if job.status == "installing" { return false }
            if ["queued", "downloading"].contains(job.status) {
                job.status = "cancelled"
                job.failedReason = nil
                job.updatedAt = JS.isoNow()
                job.activeTransfer?.cancel()
            }
            downloadJobs.removeAll { $0.jobId == jobId }
            return true
        }
    }

    func requestUpdateDownload(force: Bool) throws -> JSON {
        withState { systemUpdateStatus = NativeRuntime.updateStatus("checking", 5, "Checking RoachNet releases.") }
        let release = try resolveLatestRelease(force: force)
        let updateAvailable = compareVersions(release["latestVersion"].jsString, version) > 0
        if !updateAvailable {
            withState { systemUpdateStatus = NativeRuntime.updateStatus("idle", 100, "RoachNet is current.") }
            return ["success": true, "message": "RoachNet is current.", "note": release["pageUrl"]]
        }
        let assetUrl = release["assetUrl"].jsString
        guard release["assetUrl"].truthy, Self.isTrustedReleaseUrl(assetUrl) else {
            withState {
                systemUpdateStatus = NativeRuntime.updateStatus(
                    "error", 0, "No downloadable installer asset was found.")
            }
            return [
                "success": false, "error": "No downloadable installer asset was found.", "note": release["pageUrl"],
            ]
        }
        let expectedSha256: String
        do {
            expectedSha256 = try fetchReleaseChecksum(release)
        } catch {
            let message =
                "RoachNet \(release["latestVersion"].jsString) has no verifiable checksum; download it from the release page instead. (\(error))"
            withState { systemUpdateStatus = NativeRuntime.updateStatus("error", 0, message) }
            return ["success": false, "error": JSON(message), "note": release["pageUrl"]]
        }
        guard
            let job = try? queueDownload(
                assetUrl, Path.join(storageRoot, "updates"), "dmg", expectedSha256: expectedSha256)
        else {
            withState {
                systemUpdateStatus = NativeRuntime.updateStatus("error", 0, "Update download could not be queued.")
            }
            return ["success": false, "error": "Update download could not be queued."]
        }
        let label = (release["name"] || release["latestVersion"]).jsString
        withState { systemUpdateStatus = NativeRuntime.updateStatus("downloading", 1, "Downloading \(label).") }
        mirrorDownloadJobToUpdateStatus(job, label: label)
        return [
            "success": true,
            "message": JSON("RoachNet \(release["latestVersion"].jsString) installer download queued."),
            "note": JSON(job.filepath),
        ]
    }

    static func isTrustedReleaseUrl(_ raw: String) -> Bool {
        guard let parsed = WebURL(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if parsed.scheme == "https" { return true }
        return parsed.scheme == "http" && CompanionProxy.isLoopback(parsed.bareHostname)
    }

    func fetchReleaseChecksum(_ release: JSON) throws -> String {
        let checksumUrl = release["checksumUrl"].jsString
        guard release["checksumUrl"].truthy, Self.isTrustedReleaseUrl(checksumUrl),
            let checked = WebURL(checksumUrl.trimmingCharacters(in: .whitespacesAndNewlines))?.description
        else {
            throw RuntimeError("The release has no checksum sidecar.")
        }
        let response = try HTTPClient.request(
            checked, headers: ["accept": "text/plain"], timeoutMs: 12_000, maxResponseBytes: 4096)
        guard response.ok else { throw RuntimeError("Checksum sidecar returned HTTP \(response.status).") }
        let assetName = release["assetName"].jsString.lowercased()
        for line in response.text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
            guard let digest = fields.first?.lowercased(), JS.matches("^[0-9a-f]{64}$", digest) else { continue }
            let named = fields.dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: "*")).lowercased()
            if named == nil || named == assetName || named?.hasSuffix("/" + assetName) == true { return digest }
        }
        throw RuntimeError("Checksum sidecar does not name \(release["assetName"].jsString).")
    }

    func mirrorDownloadJobToUpdateStatus(_ job: DownloadJob, label: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(750), repeating: .milliseconds(750))
        timer.setEventHandler { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            let (status, progress, failure, filepath) = self.withState {
                (job.status, job.progress, job.failedReason, job.filepath)
            }
            if status == "completed" {
                self.withState {
                    self.systemUpdateStatus = NativeRuntime.updateStatus(
                        "ready", 100,
                        "Installer downloaded to \(filepath). Run RoachNet Setup over the existing install.")
                }
                timer.cancel()
                #if os(macOS)
                if self.config.env("ROACHNET_OPEN_UPDATES") != "0" {
                    Processes.run("/usr/bin/open", [filepath], timeoutMs: 5_000)
                }
                #endif
                return
            }
            if status == "failed" {
                self.withState {
                    self.systemUpdateStatus = NativeRuntime.updateStatus(
                        "error", 0, failure ?? "Update download failed.")
                }
                timer.cancel()
                return
            }
            self.withState {
                self.systemUpdateStatus = NativeRuntime.updateStatus("downloading", progress, "Downloading \(label).")
            }
        }
        timer.resume()
    }

    func modelPacksRootPath() -> String { Path.join(storageRoot, "RoachSpeech", "ModelPacks") }

    func readRoachSpeechPackRegistry() -> JSON {
        readJSONFile([Path.join(modelPacksRootPath(), "pending-packs.json")], [])
    }

    func upsertRoachSpeechPackRegistry(_ entry: JSON) {
        withState {
            var record = entry
            record["updatedAt"] = JSON(JS.isoNow())
            let registry = readRoachSpeechPackRegistry().array.filter { $0["packID"] != entry["packID"] }
            let next = Array(([record] + registry).prefix(50))
            try? Files.writePrettyJSON(.array(next), to: Path.join(modelPacksRootPath(), "pending-packs.json"))
        }
    }

    func findRoachSpeechPackRoot(_ candidateRoot: String, depth: Int = 0) -> String? {
        if Files.exists(Path.join(candidateRoot, "RoachSpeechPack.json")) { return candidateRoot }
        if depth >= 4 { return nil }
        for entry in Files.entries(candidateRoot) where entry.isDirectory && !entry.name.hasPrefix(".") {
            if let found = findRoachSpeechPackRoot(Path.join(candidateRoot, entry.name), depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    func validateRoachSpeechPackRoot(_ packRoot: String, _ expectedPackID: String, _ expectedKind: String) throws
        -> JSON
    {
        guard let manifest = JSON.read(contentsOf: Path.join(packRoot, "RoachSpeechPack.json")) else {
            throw RuntimeError("RoachSpeech pack manifest is unreadable.")
        }
        if manifest["packID"].stringValue != expectedPackID {
            throw RuntimeError(
                "RoachSpeech pack mismatch. Expected \(expectedPackID), found \((manifest["packID"] || "missing").jsString)."
            )
        }
        if !expectedKind.isEmpty && manifest["kind"].stringValue != expectedKind {
            throw RuntimeError(
                "RoachSpeech pack kind mismatch. Expected \(expectedKind), found \((manifest["kind"] || "missing").jsString)."
            )
        }
        if manifest["noPackagedBinary"] != .bool(true) || manifest["nativeFormat"].stringValue != "coreML" {
            throw RuntimeError("\(expectedPackID) is not a native Core ML RoachSpeech pack.")
        }
        return manifest
    }

    func installRoachSpeechPackArchive(_ job: DownloadJob, packID: String, kind: String) throws {
        let packsRoot = modelPacksRootPath()
        try Files.mkdirp(packsRoot)
        let extractRoot = Path.join(packsRoot, ".extract-\(packID)-\(JS.randomHex(6))")
        try Files.mkdirp(extractRoot)
        let finalRoot = Path.join(packsRoot, packID)
        let stagingRoot = Path.join(packsRoot, ".staging-\(packID)-\(JS.randomUUID())")
        let backupRoot = Path.join(packsRoot, ".backup-\(packID)-\(JS.randomUUID())")
        defer {
            Files.remove(extractRoot)
            Files.remove(stagingRoot)
            Files.remove(backupRoot)
        }
        do {
            guard Files.isFile(job.filepath) else {
                throw RuntimeError("Downloaded RoachSpeech pack is not a file: \(job.filepath)")
            }
            try PackArchive.unpack(job.filepath, format: "zip", into: extractRoot)
            guard let packRoot = findRoachSpeechPackRoot(extractRoot) else {
                throw RuntimeError("Downloaded archive did not contain a RoachSpeechPack.json manifest.")
            }
            _ = try validateRoachSpeechPackRoot(packRoot, packID, kind)
            try Files.rename(packRoot, stagingRoot)
            if Files.exists(finalRoot) { try Files.rename(finalRoot, backupRoot) }
            try Files.rename(stagingRoot, finalRoot)
            Files.remove(backupRoot)
            withState {
                job.installPath = finalRoot
                job.installStatus = "installed"
            }
            upsertRoachSpeechPackRegistry([
                "packID": JSON(packID), "kind": JSON(kind), "url": JSON(job.url), "status": "installed",
                "filepath": JSON(job.filepath), "installPath": JSON(finalRoot),
            ])
        } catch {
            if Files.exists(backupRoot) && !Files.exists(finalRoot) { try? Files.rename(backupRoot, finalRoot) }
            withState { job.installStatus = "failed" }
            upsertRoachSpeechPackRegistry([
                "packID": JSON(packID), "kind": JSON(kind), "url": JSON(job.url), "status": "failed",
                "filepath": JSON(job.filepath), "installPath": Files.exists(finalRoot) ? JSON(finalRoot) : nil,
                "error": JSON("\(error)"),
            ])
            throw error
        }
    }

    func queueRoachSpeechPackDownload(_ body: JSON, expectedSha256: String? = nil) throws -> (
        job: DownloadJob?, packID: String, kind: String
    ) {
        let packID = safeFileName(body["packID"] || body["pack"] || "roachspeech-pack", "roachspeech-pack")
        let kind = safeFileName(body["kind"] || "roachVoice", "roachVoice")
        let destination = Path.join(storageRoot, "RoachSpeech", "ModelPacks", ".downloads", kind, packID)
        let rawURL = (body["url"].isNullish ? "" : body["url"].jsString).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty, !isAppsDownloadDescriptorUrl(rawURL) {
            throw requestError(
                "RoachSpeech packs install only from RoachNet download descriptors (\(config.appsDownloadsBaseUrl)/…json).",
                400)
        }
        let speechPacks = packRegistry.catalogPacks.filter { $0.install?.handler == PackInstallHandler.roachSpeechPack }
        let requested = WebURL(rawURL)?.description
        let isRequested: (PackResource) -> Bool = { resource in
            guard let url = resource.url else { return false }
            return url == rawURL || (requested != nil && WebURL(url)?.description == requested)
        }
        let byURL = rawURL.isEmpty ? nil : speechPacks.first { $0.resources.contains(where: isRequested) }
        let byID = speechPacks.first { $0.id == packID }
        if let byURL, let byID, byURL.id != byID.id {
            throw requestError("That download is the \(byURL.id) pack, not \(packID).", 400)
        }
        let pinned = expectedSha256 ?? (byURL?.resources.first(where: isRequested) ?? byID?.resources.first)?.sha256
        let job = try queueResolvedDownload(body["url"], destination, "roachspeech-pack", expectedSha256: pinned) {
            [unowned self] downloadJob in
            try self.installRoachSpeechPackArchive(downloadJob, packID: packID, kind: kind)
        }
        upsertRoachSpeechPackRegistry([
            "packID": JSON(packID),
            "kind": JSON(kind),
            "url": job.map { JSON($0.url) } ?? body["url"],
            "descriptorUrl": JSON(job?.descriptorUrl),
            "expectedSha256": JSON(job?.expectedSha256),
            "status": JSON(job != nil ? "queued" : "idle"),
            "filepath": JSON(job?.filepath),
            "installPath": JSON(job?.installPath),
        ])
        return (job, packID, kind)
    }

    func roachSpeechModelPacksState() -> JSON {
        let packsRoot = modelPacksRootPath()
        let entries: [JSON] =
            Files.exists(packsRoot)
            ? Files.entries(packsRoot).filter { $0.isDirectory && !$0.name.hasPrefix(".") }.map { entry in
                let root = Path.join(packsRoot, entry.name)
                let manifest = readJSONFile([Path.join(root, "RoachSpeechPack.json")], .null)
                return [
                    "packID": JSON(entry.name), "root": JSON(root), "installed": JSON(manifest.truthy),
                    "manifest": manifest,
                ]
            }
            : []
        return [
            "success": true,
            "ok": true,
            "modelPacksRoot": JSON(packsRoot),
            "packs": .array(entries),
            "registry": readRoachSpeechPackRegistry(),
        ]
    }

    func resourcesForMapCollection(_ slug: JSON) -> [JSON] {
        (mapCollections().first { $0["slug"] == slug } ?? .undefined)["resources"].array
    }

    func resourcesForEducationTier(_ categorySlug: JSON, _ tierSlug: JSON) -> [JSON] {
        let category = educationCategories().first { $0["slug"] == categorySlug } ?? .undefined
        return (category["tiers"].array.first { $0["slug"] == tierSlug } ?? .undefined)["resources"].array
    }

    func resourcesForEducationResource(_ categorySlug: JSON, _ resourceId: JSON) -> [JSON] {
        let category = educationCategories().first { $0["slug"] == categorySlug } ?? .undefined
        return category["tiers"].array.flatMap { $0["resources"].array }.filter { $0["id"] == resourceId }
    }

    func queueResources(_ resources: [JSON], _ destination: String, _ filetype: String) throws -> [DownloadJob] {
        var jobs: [DownloadJob] = []
        var firstError: Error?
        for resource in resources {
            do {
                if let job = try queueResolvedDownload(
                    resource["descriptorUrl"] || resource["url"], destination, filetype)
                {
                    jobs.append(job)
                }
            } catch {
                firstError = firstError ?? error
                log("could not queue \((resource["descriptorUrl"] || resource["url"]).jsString): \(error)")
            }
        }
        if jobs.isEmpty, let firstError { throw firstError }
        return jobs
    }

    func appStoreInstallResponse(
        _ action: String, _ jobs: [DownloadJob], _ message: String, _ extra: JSONObject = JSONObject()
    ) -> JSON {
        let success = !jobs.isEmpty || extra["success"] == .bool(true)
        var response: JSON = [
            "success": JSON(success),
            "ok": JSON(success),
            "action": JSON(action),
            "message": JSON(message),
            "jobId": JSON(jobs.first?.jobId),
            "jobIds": jsonStrings(jobs.map(\.jobId)),
            "queued": JSON(jobs.count),
        ]
        for (key, value) in extra { response[key] = value }
        return response
    }

    func queueWorldAtlasInBackground() -> Bool {
        let pmtiles = Path.join(storageRoot, "maps", "pmtiles")
        let names = ["global-min_2026-10.pmtiles", "global-min_2025-12.pmtiles"]
        if names.contains(where: { Files.exists(Path.join(pmtiles, $0)) }) { return false }
        let descriptor =
            "\(JS.replace("/+$", in: config.appsDownloadsBaseUrl, with: ""))/maps/pmtiles/global-min_2026-10.json"
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                _ = try queueResolvedDownload(JSON(descriptor), pmtiles, "pmtiles")
            } catch {
                log("world atlas not queued: \(error)")
            }
        }
        return true
    }

    func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    func handleCompanionInstall(_ body: JSON) throws -> JSON {
        let action = (body["action"] || body["type"] || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines)
        if action.isEmpty { throw requestError("App Store install action is missing.", 400) }
        let pmtiles = Path.join(storageRoot, "maps", "pmtiles")
        let zim = Path.join(storageRoot, "zim")
        func trimmed(_ value: JSON) -> String { (value || "").jsString.trimmingCharacters(in: .whitespacesAndNewlines) }

        switch action {
        case "base-map-assets":
            try Files.mkdirp(pmtiles)
            try Files.mkdirp(Path.join(storageRoot, "maps", "basemaps-assets"))
            let queued = queueWorldAtlasInBackground()
            return appStoreInstallResponse(
                action, [],
                queued
                    ? "Base atlas folders are ready. The World Atlas download is starting."
                    : "Base atlas folders are ready.", JSONObject([("success", true)]))
        case "map-collection":
            let slug = trimmed(body["slug"])
            if slug.isEmpty { throw requestError("Map collection slug is missing.", 400) }
            let jobs = try queueResources(resourcesForMapCollection(JSON(slug)), pmtiles, "pmtiles")
            return appStoreInstallResponse(
                action, jobs, "\(plural(jobs.count, "map download")) queued.", JSONObject([("slug", JSON(slug))]))
        case "education-tier":
            let categorySlug = trimmed(body["categorySlug"] || body["category"])
            let tierSlug = trimmed(body["tierSlug"] || body["tier"])
            if categorySlug.isEmpty || tierSlug.isEmpty {
                throw requestError("Education tier install needs category and tier.", 400)
            }
            let jobs = try queueResources(resourcesForEducationTier(JSON(categorySlug), JSON(tierSlug)), zim, "zim")
            return appStoreInstallResponse(
                action, jobs, "\(plural(jobs.count, "knowledge download")) queued.",
                JSONObject([("categorySlug", JSON(categorySlug)), ("tierSlug", JSON(tierSlug))]))
        case "education-resource":
            let categorySlug = trimmed(body["categorySlug"] || body["category"])
            let resourceId = trimmed(body["resourceId"] || body["resource"])
            if categorySlug.isEmpty || resourceId.isEmpty {
                throw requestError("Education resource install needs category and resource.", 400)
            }
            let jobs = try queueResources(
                resourcesForEducationResource(JSON(categorySlug), JSON(resourceId)), zim, "zim")
            return appStoreInstallResponse(
                action, jobs, "\(plural(jobs.count, "knowledge download")) queued.",
                JSONObject([("categorySlug", JSON(categorySlug)), ("resourceId", JSON(resourceId))]))
        case "direct-download":
            let rawUrl = body["url"] || body["mirrorUrl"] || body["sourceUrl"]
            let filetype = (body["filetype"] || body["resourceType"] || "").jsString.lowercased()
            if !rawUrl.truthy { throw requestError("Direct App Store download URL is missing.", 400) }
            if ["map", "pmtiles"].contains(filetype) {
                let job = try queueResolvedDownload(rawUrl, pmtiles, "pmtiles")
                return appStoreInstallResponse(
                    action, job.map { [$0] } ?? [], job != nil ? "Map download queued." : "No map URL provided.",
                    JSONObject([("filetype", JSON(filetype))]))
            }
            if ["zim", "knowledge", "education"].contains(filetype) {
                let job = try queueResolvedDownload(rawUrl, zim, "zim")
                return appStoreInstallResponse(
                    action, job.map { [$0] } ?? [], job != nil ? "Knowledge pack queued." : "No ZIM URL provided.",
                    JSONObject([("filetype", JSON(filetype))]))
            }
            throw requestError(
                "Unsupported direct App Store download type: \(filetype.isEmpty ? "unknown" : filetype).", 400)
        case "wikipedia-option":
            let optionId = trimmed(body["optionId"] || body["option"])
            let (job, option) = try selectWikipediaOption(JSON(optionId))
            if job == nil && option == nil {
                return appStoreInstallResponse(
                    action, [], "Wikipedia install skipped.",
                    JSONObject([("success", true), ("optionId", JSON(optionId.isEmpty ? "none" : optionId))]))
            }
            return appStoreInstallResponse(
                action, job.map { [$0] } ?? [], "\(option!["name"].jsString) queued.",
                JSONObject([("optionId", option!["id"])]))
        case "roachclaw-model":
            let model = trimmed(body["model"])
            if model.isEmpty { throw requestError("RoachClaw model name is missing.", 400) }
            pullModel(model)
            return appStoreInstallResponse(
                action, [], "\(model) model pull queued.", JSONObject([("success", true), ("model", JSON(model))]))
        case "roachspeech-pack", "roachvoice-pack":
            if !body["url"].truthy { throw requestError("RoachSpeech pack URL is missing.", 400) }
            let queued = try queueRoachSpeechPackDownload(body)
            return appStoreInstallResponse(
                action,
                queued.job.map { [$0] } ?? [],
                queued.job != nil
                    ? "\(queued.packID) RoachSpeech pack queued. It will unpack into the local model shelf when the download finishes."
                    : "No RoachSpeech pack URL provided.",
                JSONObject([("packID", JSON(queued.packID)), ("kind", JSON(queued.kind))])
            )
        case "pack":
            let id = trimmed(body["pack"] || body["id"] || body["packID"])
            if id.isEmpty { throw requestError("Pack id is missing.", 400) }
            let result = try installPack(["id": JSON(id)])
            let installed = result["status"].jsString == "installed"
            return appStoreInstallResponse(
                action,
                [],
                installed
                    ? "\(id) is already installed."
                    : "\(id) pack queued. Settings › Packs on the Mac shows its progress.",
                JSONObject([("success", true), ("packID", JSON(id)), ("status", result["status"])])
            )
        default:
            throw requestError("Unsupported App Store install action: \(action).", 400)
        }
    }

    func selectWikipediaOption(_ optionId: JSON) throws -> (DownloadJob?, JSON?) {
        let option = wikipediaOptions().first { $0["id"] == optionId }
        try Files.mkdirp(Path.join(storageRoot, "zim"))
        guard let option, option["id"].stringValue != "none", option["url"].truthy else {
            try Files.writePrettyJSON(
                [
                    "optionId": optionId.truthy ? optionId : "none",
                    "status": "skipped",
                    "filename": nil,
                    "url": nil,
                ], to: wikipediaSelectionPath())
            return (nil, nil)
        }
        let descriptorUrl = descriptorUrlForSource(option["url"], "content/wikipedia")
        let job = try queueResolvedDownload(descriptorUrl || option["url"], Path.join(storageRoot, "zim"), "zim")
        try Files.writePrettyJSON(
            [
                "optionId": option["id"],
                "status": JSON(job != nil ? "queued" : "idle"),
                "filename": JSON(fileNameForUrl(option["url"], "\(option["id"].jsString).zim")),
                "url": option["url"],
                "descriptorUrl": descriptorUrl,
            ], to: wikipediaSelectionPath())
        return (job, option)
    }

    func handleChat(_ body: JSON, sessionId: String? = nil, source: String = "app", allowPlans: Bool) -> JSON {
        let requested = body["model"].stringValue ?? ""
        let plan = SubscriptionModels.parse(requested) != nil
        if plan && !allowPlans {
            return [
                "message": ["role": "assistant", "content": JSON(Self.planModelsRefusal)],
                "error": JSON(Self.planModelsRefusal),
            ]
        }
        ensureOllama()
        let model = body["model"].stringValue ?? defaultModel
        let trace = tracer.startTrace(
            kind: "chat", name: "RoachClaw chat · \(model)", sessionId: sessionId, tags: ["roachclaw", source],
            input: body["messages"], metadata: JSONObject([("source", JSON(source))]))
        let generation = trace?.observation(
            .generation, model, input: body["messages"], model: model,
            provider: modelServerIsOllama ? "ollama" : "roachinference")
        var headers: [String: String] = [:]
        if let generation { headers["traceparent"] = generation.traceparent }
        if plan, isOwnRoachInference(modelServerBaseUrl) { headers[Self.planKeyHeader] = planKey }
        do {
            let reply = try HTTPClient.fetchJSON(
                urlJoin("/api/chat", modelServerBaseUrl), method: "POST", headers: headers, body: body.serializedData(),
                timeoutMs: 120_000)
            let usage = TraceUsage(
                inputTokens: (reply["prompt_eval_count"].clampedInt(0...(1 << 50)) ?? 0),
                outputTokens: (reply["eval_count"].clampedInt(0...(1 << 50)) ?? 0))
            generation?.end(output: reply["message"]["content"], usage: usage, cost: .local)
            trace?.end(status: "ok", output: reply["message"]["content"])
            return reply
        } catch {
            let reason = "Local model route is not ready: \(error)"
            generation?.end(level: .error, statusMessage: "\(error)")
            trace?.end(status: "error", message: reason)
            return ["message": ["role": "assistant", "content": JSON(reason)], "error": JSON(reason)]
        }
    }

    @discardableResult
    func pullModel(_ model: String) -> Bool {
        let requested = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if requested.isEmpty { return false }
        guard let name = try? NativeModelStore.normalize(requested).name else {
            log("model pull refused: \(requested.debugDescription) is not a model name")
            return false
        }
        guard modelPulls.begin(name) else { return false }
        let inProcess: Bool
        if pullsModelsInProcess {
            inProcess = true
        } else {
            ensureOllama()
            inProcess = pullsModelsInProcess
        }
        installedModelsCache.invalidate(modelServerBaseUrl)
        modelPullQueue.async {
            var failure: String?
            if self.modelPulls.stopRequested(name) {
                failure = "Stopped before it started."
            } else {
                _ = self.modelPulls.update(name, ["status": "pulling manifest"])
                do {
                    if inProcess {
                        _ = try self.nativeModelStore.pull(requested, request: [:]) { status in
                            self.modelPulls.update(name, status)
                        }
                    } else {
                        let url = self.urlJoin("/api/pull", self.modelServerBaseUrl)
                        let body: JSON = ["name": JSON(requested), "stream": false]
                        _ = try HTTPClient.fetchJSON(
                            url, method: "POST", body: body.serializedData(), timeoutMs: 600_000)
                    }
                } catch {
                    failure = (error as? RuntimeError)?.message ?? "\(error)"
                    self.log("model pull failed: \(error)")
                }
            }
            self.modelPulls.finish(name, error: failure)
            self.installedModelsCache.invalidate(self.modelServerBaseUrl)
        }
        return true
    }
}
