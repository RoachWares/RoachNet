import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct TracePrice: Codable, Equatable {
    /// US dollars per million tokens, as the person entered them. RoachNet ships
    /// no price list: provider prices change, and a stale one would be a guess.
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cachedInputPerMTok: Double?
}

public struct TraceExportSettings: Codable, Equatable {
    public var enabled = false
    /// OTLP/HTTP base, e.g. `https://cloud.langfuse.com/api/public/otel` or a collector's `http://127.0.0.1:4318`.
    public var endpoint = ""
    public var includeContent = false
    /// Sent with every export (for Langfuse: `Authorization: Basic …`). Stored
    /// owner-only and never returned by the API, only their names.
    public var headers: [String: String] = [:]
    public var serviceName = "roachnet"
    public var environment = "local"
}

public struct TraceSettings: Codable, Equatable {
    public var enabled = true
    public var captureContent = true
    public var maxContentChars = 16_000
    public var retentionDays = 30
    /// Trace every request the model server answers, not only the ones an Org run or chat makes.
    public var traceModelServer = true
    public var export = TraceExportSettings()
    public var pricing: [String: TracePrice] = [:]
}

/// Owner-only JSONL files, one per UTC day (`<root>/2026-10-11.jsonl`). Every
/// line is an upsert (`t` trace, `o` observation, `s` score) or a delete (`d`);
/// a later line for the same id wins. Recent records are indexed in memory.
public final class TraceStore {
    public static let memoryTraceCap = 20_000
    /// How far past the cap the index may run before it trims (trimming sorts every trace).
    static let replaySlack = 1_000
    public let root: String
    private let lock = NSRecursiveLock()
    private var traces: [String: TraceRecord] = [:]
    private var observations: [String: [String: ObservationRecord]] = [:]
    private var scores: [String: [ScoreRecord]] = [:]
    private var lastPurgeMs: Int64 = 0
    public private(set) var settings: TraceSettings

    private struct Line: Codable {
        var k: String
        var t: TraceRecord?
        var o: ObservationRecord?
        var s: ScoreRecord?
        var id: String?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(root: String) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        chmod(root, 0o700)
        if let data = FileManager.default.contents(atPath: Path.join(root, "settings.json")),
           let decoded = try? JSONDecoder().decode(TraceSettings.self, from: data) {
            settings = decoded
        } else {
            settings = TraceSettings()
        }
        purgeExpired(force: true)
        loadRecentDays()
    }

    // MARK: Settings

    public func updateSettings(_ change: (inout TraceSettings) -> Void) throws -> TraceSettings {
        lock.lock(); defer { lock.unlock() }
        var next = settings
        change(&next)
        next.maxContentChars = min(max(next.maxContentChars, 256), 1_000_000)
        next.retentionDays = min(max(next.retentionDays, 1), 3_650)
        let data = try TraceStore.encoder.encode(next)
        try Files.write(data, to: Path.join(root, "settings.json"), mode: Files.privateFileMode)
        settings = next
        return next
    }

    // MARK: Writes

    public func upsert(_ trace: TraceRecord) {
        lock.lock(); defer { lock.unlock() }
        traces[trace.id] = trace
        append(Line(k: "t", t: trace), day: TraceClock.day(trace.startMs))
        // Trimming sorts every trace, so it waits until the index is a little past
        // the cap (once per `replaySlack` new traces, not on every one past it).
        if traces.count > TraceStore.memoryTraceCap + TraceStore.replaySlack { capMemory() }
    }

    public func upsert(_ observation: ObservationRecord) {
        lock.lock(); defer { lock.unlock() }
        observations[observation.traceId, default: [:]][observation.id] = observation
        let day = traces[observation.traceId].map { TraceClock.day($0.startMs) } ?? TraceClock.day(observation.startMs)
        append(Line(k: "o", o: observation), day: day)
    }

    public func add(_ score: ScoreRecord) {
        lock.lock(); defer { lock.unlock() }
        scores[score.traceId, default: []].removeAll { $0.id == score.id }
        scores[score.traceId, default: []].append(score)
        let day = traces[score.traceId].map { TraceClock.day($0.startMs) } ?? TraceClock.day(score.createdMs)
        append(Line(k: "s", s: score), day: day)
    }

    @discardableResult
    public func delete(_ traceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let trace = traces.removeValue(forKey: traceId) else { return false }
        observations.removeValue(forKey: traceId)
        scores.removeValue(forKey: traceId)
        append(Line(k: "d", id: traceId), day: TraceClock.day(trace.startMs))
        return true
    }

    // MARK: Reads

    public func trace(_ id: String) -> TraceRecord? {
        lock.lock(); defer { lock.unlock() }
        return traces[id]
    }

    public func observation(_ traceId: String, _ id: String) -> ObservationRecord? {
        lock.lock(); defer { lock.unlock() }
        return observations[traceId]?[id]
    }

    public func observations(_ traceId: String) -> [ObservationRecord] {
        lock.lock(); defer { lock.unlock() }
        return (observations[traceId]?.values.map { $0 } ?? []).sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
    }

    public func scores(_ traceId: String) -> [ScoreRecord] {
        lock.lock(); defer { lock.unlock() }
        return (scores[traceId] ?? []).sorted { $0.createdMs < $1.createdMs }
    }

    /// Newest first. `matching` filters; the cursor is the last item's `startMs:id`.
    public func list(limit: Int, cursor: String?, matching: (TraceRecord) -> Bool) -> (items: [TraceRecord], next: String?) {
        lock.lock()
        let all = traces.values.filter(matching)
        lock.unlock()
        var sorted = all.sorted { ($0.startMs, $0.id) > ($1.startMs, $1.id) }
        if let cursor, let colon = cursor.firstIndex(of: ":"), let ms = Int64(cursor[..<colon]) {
            let id = String(cursor[cursor.index(after: colon)...])
            sorted = sorted.filter { ($0.startMs, $0.id) < (ms, id) }
        }
        let page = Array(sorted.prefix(max(1, min(limit, 500))))
        let next = sorted.count > page.count ? page.last.map { "\($0.startMs):\($0.id)" } : nil
        return (page, next)
    }

    public func allTraces(matching: (TraceRecord) -> Bool) -> [TraceRecord] {
        lock.lock(); defer { lock.unlock() }
        return traces.values.filter(matching)
    }

    // MARK: Files

    private func dayPath(_ day: String) -> String { Path.join(root, "\(day).jsonl") }

    private func append(_ line: Line, day: String) {
        guard var data = try? TraceStore.encoder.encode(line) else { return }
        data.append(0x0A)
        let path = dayPath(day)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = write(fd, base + written, buffer.count - written)
                if count <= 0 { break }
                written += count
            }
        }
        close(fd)
        purgeExpired(force: false)
    }

    private func dayFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && $0.count == 16 }
            .map { String($0.prefix(10)) }
            .sorted()
    }

    /// Newest days first, until the in-memory cap is reached.
    private func loadRecentDays() {
        let decoder = JSONDecoder()
        for day in dayFiles().reversed() {
            guard traces.count < TraceStore.memoryTraceCap, let text = Files.readText(dayPath(day)) else { break }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)) else { continue }
                switch line.k {
                case "t":
                    if let trace = line.t {
                        traces[trace.id] = trace
                        // One day's file can hold more than the cap (capMemory trims memory,
                        // not the file), so trim while replaying, not only before each day.
                        if traces.count > TraceStore.memoryTraceCap + TraceStore.replaySlack { capMemory() }
                    }
                case "o": if let observation = line.o { observations[observation.traceId, default: [:]][observation.id] = observation }
                case "s": if let score = line.s { scores[score.traceId, default: []].removeAll { $0.id == score.id }; scores[score.traceId, default: []].append(score) }
                case "d": if let id = line.id { traces.removeValue(forKey: id); observations.removeValue(forKey: id); scores.removeValue(forKey: id) }
                default: break
                }
            }
        }
        capMemory()
        // Observations and scores whose trace was deleted, trimmed or never written.
        for key in observations.keys where traces[key] == nil { observations.removeValue(forKey: key) }
        for key in scores.keys where traces[key] == nil { scores.removeValue(forKey: key) }
        // A trace left "running" by an earlier process will never finish.
        for (id, trace) in traces where trace.status == "running" && trace.endMs == nil {
            var closed = trace
            closed.status = "error"
            closed.statusMessage = "RoachNet stopped before this trace finished."
            closed.endMs = observations[id]?.values.compactMap(\.endMs).max() ?? trace.startMs
            traces[id] = closed
        }
    }

    private func capMemory() {
        guard traces.count > TraceStore.memoryTraceCap else { return }
        let drop = traces.values.sorted { $0.startMs < $1.startMs }.prefix(traces.count - TraceStore.memoryTraceCap)
        for trace in drop {
            traces.removeValue(forKey: trace.id)
            observations.removeValue(forKey: trace.id)
            scores.removeValue(forKey: trace.id)
        }
    }

    /// Removes day files past the retention window (at most once an hour).
    public func purgeExpired(force: Bool) {
        let now = TraceClock.nowMs()
        guard force || now - lastPurgeMs > 3_600_000 else { return }
        lastPurgeMs = now
        let cutoff = TraceClock.day(now - Int64(settings.retentionDays) * 86_400_000)
        for day in dayFiles() where day < cutoff {
            Files.remove(dayPath(day))
        }
        let cutoffMs = now - Int64(settings.retentionDays) * 86_400_000
        for (id, trace) in traces where trace.startMs < cutoffMs {
            traces.removeValue(forKey: id); observations.removeValue(forKey: id); scores.removeValue(forKey: id)
        }
    }
}
