import XCTest
@testable import RoachNetRuntime

/// A download never writes through a link someone put at its partial file,
/// and only one download writes a given file at a time (ROA-95).
final class DownloadSafetyTests: XCTestCase {
    private var root = ""
    private var server: LoopbackHTTPServer?
    private let payload = Data("a ZIM file".utf8)
    private var storage: String { Path.join(root, "storage") }
    private var outside: String { Path.join(root, "outside") }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-download-safety-" + JS.randomHex(6)
        try Files.mkdirp(Path.join(storage, "zim"))
        try Files.mkdirp(outside)
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Descriptors `/downloads/zim/<name>.json` point to `/<name>.zim` and name
    /// `names[name]`, or `item.zim`. A `slow` file waits before it answers; a
    /// `missing` one is a 404.
    private func runtime(slow: Set<String> = [], names: [String: String] = [:], missing: Set<String> = []) throws -> NativeRuntime {
        let port = LockedBox<Int>(0)
        let body = payload
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: 0, maxBodyBytes: 1024) { request in
            let target = request.target
            if target.hasPrefix("/downloads/zim/"), target.hasSuffix(".json") {
                let name = String(target.dropFirst("/downloads/zim/".count).dropLast(".json".count))
                let descriptor: JSON = ["url": JSON("http://127.0.0.1:\(port.value)/\(name).zim"), "filename": JSON(names[name] ?? "item.zim")]
                let data = Data(descriptor.serialized().utf8)
                var response = HTTPResponse(status: 200, headers: [("content-type", "application/json"), ("content-length", String(data.count))])
                response.body = data
                return response
            }
            if target.hasSuffix(".zim") {
                let name = String(target.dropFirst().dropLast(4))
                if missing.contains(name) { return HTTPResponse(status: 404, headers: [("content-length", "0")]) }
                if slow.contains(name) { Thread.sleep(forTimeInterval: 1.5) }
                var response = HTTPResponse(status: 200, headers: [("content-type", "application/octet-stream"), ("content-length", String(body.count))])
                response.body = body
                return response
            }
            return HTTPResponse(status: 404, headers: [("content-length", "0")])
        }
        try server.start()
        self.server = server
        port.value = Int(server.port)
        return NativeRuntime(config: RuntimeConfiguration(environment: [
            "ROACHNET_STORAGE_PATH": storage,
            "ROACHNET_APPS_DOWNLOADS_BASE_URL": "http://127.0.0.1:\(server.port)/downloads",
            "ROACHNET_NATIVE_API_DOWNLOAD_MAX_ATTEMPTS": "1",
        ]))
    }

    private func descriptor(_ name: String) -> JSON { JSON("http://127.0.0.1:\(server!.port)/downloads/zim/\(name).json") }

    private func finish(_ job: DownloadJob, on runtime: NativeRuntime) -> String {
        let deadline = Date().addingTimeInterval(20)
        while ["queued", "downloading", "installing"].contains(runtime.withState({ job.status })), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return runtime.withState { job.status }
    }

    private func waitForWriters(_ runtime: NativeRuntime) {
        let deadline = Date().addingTimeInterval(20)
        while !runtime.withState({ runtime.downloadWriters.isEmpty }), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func linkCount(_ path: String) -> Int { Int(Files.lstatInfo(path)?.st_nlink ?? 0) }

    func testALinkAtThePartialFileIsNeverWrittenThrough() throws {
        let runtime = try runtime()
        let victim = Path.join(outside, "notes.txt")
        let original = Data("keep me".utf8)
        try Files.write(original, to: victim)
        let partial = Path.join(storage, "zim", "item.zim.part")
        try FileManager.default.createSymbolicLink(atPath: partial, withDestinationPath: victim)
        // A resume marker that matches, so the download would resume into it.
        let url = "http://127.0.0.1:\(server!.port)/first.zim"
        try Files.writePrettyJSON(["url": JSON(url), "sha256": .null], to: partial + ".json")

        let job = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), Path.join(storage, "zim"), "zim"))
        XCTAssertEqual(finish(job, on: runtime), "completed")
        XCTAssertEqual(FileManager.default.contents(atPath: victim), original, "the link's target is untouched")
        XCTAssertEqual(FileManager.default.contents(atPath: job.filepath), payload)
        XCTAssertNil(Files.lstatInfo(partial), "the link is gone, not followed")
    }

    func testAHardLinkAtThePartialFileIsNeverWrittenThrough() throws {
        let runtime = try runtime()
        let url = "http://127.0.0.1:\(server!.port)/first.zim"
        let partial = Path.join(storage, "zim", "item.zim.part")
        for resume in [true, false] {
            let victim = Path.join(outside, "notes-\(resume).txt")
            let original = Data("keep me".utf8)
            try Files.write(original, to: victim)
            XCTAssertEqual(link(victim, partial), 0)
            if resume { try Files.writePrettyJSON(["url": JSON(url), "sha256": .null], to: partial + ".json") }
            let job = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), Path.join(storage, "zim"), "zim"))
            XCTAssertEqual(finish(job, on: runtime), "completed")
            XCTAssertEqual(FileManager.default.contents(atPath: victim), original, "resume: \(resume)")
            XCTAssertEqual(linkCount(victim), 1, "only the victim's own name is left")
            XCTAssertEqual(FileManager.default.contents(atPath: job.filepath), payload)
            waitForWriters(runtime)
            Files.removeFile(job.filepath)
        }
    }

    func testOneDownloadWritesAFileAtATime() throws {
        let runtime = try runtime(slow: ["first"])
        let destination = Path.join(storage, "zim")
        let first = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), destination, "zim"))
        // The same download again is the same job.
        XCTAssertTrue(try runtime.queueResolvedDownload(descriptor("first"), destination, "zim") === first)
        // Another source for the same file waits its turn instead of sharing the partial file.
        XCTAssertThrowsError(try runtime.queueResolvedDownload(descriptor("second"), destination, "zim")) { error in
            XCTAssertTrue("\(error)".contains("already running"), "\(error)")
        }
        XCTAssertThrowsError(try runtime.downloadNow(descriptor("second"), to: Path.join(destination, "item.zim"), filetype: "zim", expectedSha256: nil)) { error in
            XCTAssertTrue("\(error)".contains("already running"), "\(error)")
        }
        XCTAssertEqual(finish(first, on: runtime), "completed")
        XCTAssertEqual(FileManager.default.contents(atPath: first.filepath), payload)
        waitForWriters(runtime)
        let second = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("second"), destination, "zim"))
        XCTAssertEqual(finish(second, on: runtime), "completed")
    }

    func testACancelledDownloadHoldsItsFileUntilItsWorkerStops() throws {
        let runtime = try runtime(slow: ["first"])
        let destination = Path.join(storage, "zim")
        let filepath = Path.join(destination, "item.zim")
        // A cancelled download whose worker is still unwinding keeps its file.
        let unwinding = DownloadJob(url: "http://127.0.0.1:\(server!.port)/first.zim", filepath: filepath, filetype: "zim",
                                    descriptorUrl: nil, expectedSha256: nil, parts: [])
        runtime.withState {
            unwinding.status = "cancelled"
            runtime.downloadWriters[runtime.downloadPathKey(filepath)] = unwinding
        }
        XCTAssertThrowsError(try runtime.queueResolvedDownload(descriptor("first"), destination, "zim")) { error in
            XCTAssertTrue("\(error)".contains("already running"), "\(error)")
        }
        runtime.releaseDownloadWriter(unwinding)

        // With a real worker: cancel, then queue again once it has stopped.
        let first = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), destination, "zim"))
        XCTAssertTrue(runtime.cancelDownloadJob(first.jobId))
        waitForWriters(runtime)
        XCTAssertEqual(runtime.withState { first.status }, "cancelled")
        let again = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), destination, "zim"))
        XCTAssertFalse(again === first)
        XCTAssertEqual(finish(again, on: runtime), "completed")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(FileManager.default.contents(atPath: again.filepath), payload, "the first worker's cleanup left the new file alone")
    }

    func testAnInstallIsNotCancelledHalfway() throws {
        let runtime = try runtime()
        let destination = Path.join(storage, "zim")
        let release = DispatchSemaphore(value: 0)
        let job = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), destination, "zim") { _ in release.wait() })
        let deadline = Date().addingTimeInterval(10)
        while runtime.withState({ job.status }) != "installing", Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(runtime.withState { job.status }, "installing")
        XCTAssertFalse(runtime.cancelDownloadJob(job.jobId), "an install already running can't be stopped halfway")
        XCTAssertTrue(try runtime.queueResolvedDownload(descriptor("first"), destination, "zim") === job)
        XCTAssertThrowsError(try runtime.queueResolvedDownload(descriptor("second"), destination, "zim"))
        release.signal()
        XCTAssertEqual(finish(job, on: runtime), "completed")
    }

    func testDownloadNowReportsAFailure() throws {
        let runtime = try runtime(missing: ["gone"])
        XCTAssertThrowsError(try runtime.downloadNow(descriptor("gone"), to: Path.join(storage, "zim", "gone.zim"), filetype: "zim", expectedSha256: nil))
        let job = try XCTUnwrap(runtime.withState { runtime.downloadJobs.first { $0.filepath.hasSuffix("gone.zim") } })
        XCTAssertEqual(runtime.withState { job.status }, "failed")
        XCTAssertTrue(runtime.withState { runtime.downloadWriters.isEmpty }, "a failed download frees its file")
    }

    func testOneResourceThatCantBeQueuedDoesntStopTheRest() throws {
        let runtime = try runtime(slow: ["first"], names: ["other": "other.zim"])
        let destination = Path.join(storage, "zim")
        let first = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("first"), destination, "zim"))
        // "second" wants item.zim, which "first" is writing; "other" is free.
        let jobs = try runtime.queueResources([["url": descriptor("second")], ["url": descriptor("other")]], destination, "zim")
        XCTAssertEqual(jobs.map { Path.basename($0.filepath) }, ["other.zim"])
        XCTAssertThrowsError(try runtime.queueResources([["url": descriptor("second")]], destination, "zim"), "nothing could be queued")
        XCTAssertEqual(finish(first, on: runtime), "completed")
        XCTAssertEqual(finish(jobs[0], on: runtime), "completed")
    }

    #if canImport(Darwin)
    func testNamesThatDifferOnlyInCaseAreOneFileOnAMac() throws {
        let runtime = try runtime(slow: ["upper"], names: ["upper": "Item.zim", "lower": "item.zim"])
        let destination = Path.join(storage, "zim")
        let upper = try XCTUnwrap(runtime.queueResolvedDownload(descriptor("upper"), destination, "zim"))
        XCTAssertThrowsError(try runtime.queueResolvedDownload(descriptor("lower"), destination, "zim")) { error in
            XCTAssertTrue("\(error)".contains("already running"), "\(error)")
        }
        XCTAssertEqual(finish(upper, on: runtime), "completed")
    }
    #endif
}
