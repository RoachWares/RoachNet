import Foundation

public enum TraceObservationType: String, Codable, CaseIterable {
    case span, generation, event, agent, tool, chain, retriever, embedding, guardrail, evaluator
}

public enum TraceLevel: String, Codable {
    case debug = "DEBUG"
    case `default` = "DEFAULT"
    case warning = "WARNING"
    case error = "ERROR"
}

public struct TraceUsage: Codable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static func + (lhs: TraceUsage, rhs: TraceUsage) -> TraceUsage {
        TraceUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens)
    }

    public var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cachedInputTokens == 0 }
}

public struct TraceCost: Codable, Equatable {
    public var totalUsd: Double = 0
    public var status: String = "unpriced"
    public var billingType: String = "unknown"

    public init(totalUsd: Double = 0, status: String = "unpriced", billingType: String = "unknown") {
        self.totalUsd = totalUsd.isFinite ? max(0, totalUsd) : 0
        self.status = status
        self.billingType = billingType
    }

    public static let local = TraceCost(totalUsd: 0, status: "reported", billingType: "local")
}

public struct TraceRecord: Codable {
    public var id: String
    public var kind: String
    public var name: String
    public var companyId: String?
    public var agentId: String?
    public var issueId: String?
    public var runId: String?
    public var sessionId: String?
    public var userId: String?
    public var tags: [String] = []
    public var input: JSON = .null
    public var output: JSON = .null
    public var metadata: JSON = .object(JSONObject())
    public var status: String = "running"
    public var statusMessage: String?
    public var startMs: Int64
    public var endMs: Int64?
    public var usage = TraceUsage()
    public var costUsd: Double = 0
    public var unpriced: Bool = false
    public var observationCount: Int = 0

    public var latencyMs: Int64? { endMs.map { $0 - startMs } }
}

public struct ObservationRecord: Codable {
    public var id: String
    public var traceId: String
    public var parentId: String?
    public var type: TraceObservationType
    public var name: String
    public var level: TraceLevel = .default
    public var statusMessage: String?
    public var startMs: Int64
    public var endMs: Int64?
    public var completionStartMs: Int64?
    public var input: JSON = .null
    public var output: JSON = .null
    public var metadata: JSON = .object(JSONObject())
    public var model: String?
    public var provider: String?
    public var modelParameters: JSON = .null
    public var usage: TraceUsage?
    public var cost: TraceCost?
    public var promptTokensPerSecond: Double?
    public var outputTokensPerSecond: Double?

    public var latencyMs: Int64? { endMs.map { $0 - startMs } }
    public var timeToFirstTokenMs: Int64? { completionStartMs.map { $0 - startMs } }
}

public struct ScoreRecord: Codable {
    public var id: String
    public var traceId: String
    public var observationId: String?
    public var name: String
    public var dataType: String
    public var value: Double?
    public var stringValue: String?
    public var comment: String?
    public var source: String
    public var authorId: String?
    public var createdMs: Int64
}

public enum TraceClock {
    public static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
    public static func iso(_ ms: Int64?) -> JSON {
        guard let ms else { return .null }
        return JSON(JS.iso(Date(timeIntervalSince1970: Double(ms) / 1_000)))
    }
    public static func day(_ ms: Int64) -> String {
        String(JS.iso(Date(timeIntervalSince1970: Double(ms) / 1_000)).prefix(10))
    }
}

public enum TraceIDs {
    public static func trace() -> String { JS.randomHex(32) }
    public static func observation() -> String { JS.randomHex(16) }
    public static func isTraceId(_ value: String) -> Bool { value.count == 32 && value.allSatisfy(\.isHexDigit) }
    public static func isObservationId(_ value: String) -> Bool { value.count == 16 && value.allSatisfy(\.isHexDigit) }

    public static func traceparent(_ traceId: String, _ observationId: String) -> String {
        "00-\(traceId)-\(observationId)-01"
    }

    public static func parseTraceparent(_ header: String?) -> (traceId: String, parentId: String)? {
        guard let parts = header?.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "-"),
            parts.count == 4,
            parts[0] == "00", isTraceId(String(parts[1])), isObservationId(String(parts[2]))
        else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}
