import Foundation

public struct RoachModelLibraryEntry: Decodable, Identifiable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let use: String
    public let publisher: String
    public let license: String
    public let family: String
    public let parameterSize: String
    public let quantization: String
    public let size: Int64
    public let memoryNeeded: Int64
    public let fit: String
    public let recommended: Bool
    public let installed: Bool?

    public var id: String { name }
    public var fitsThisMac: Bool { fit != "too-big" }
    public var isCodeModel: Bool { use == "code" }

    public init(
        name: String, title: String, use: String, publisher: String, license: String, family: String,
        parameterSize: String, quantization: String, size: Int64, memoryNeeded: Int64, fit: String,
        recommended: Bool, installed: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.use = use
        self.publisher = publisher
        self.license = license
        self.family = family
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.size = size
        self.memoryNeeded = memoryNeeded
        self.fit = fit
        self.recommended = recommended
        self.installed = installed
    }
}

public struct RoachModelPull: Decodable, Equatable, Sendable {
    public let name: String
    public let state: String
    public let phase: String
    public let completed: Int64
    public let total: Int64?
    public let message: String?

    public var isActive: Bool { state == "running" }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public struct RoachModelLibrary: Decodable, Equatable, Sendable {
    public let models: [RoachModelLibraryEntry]
    public let pulls: [RoachModelPull]
    public let memoryBytes: Int64
    public let budgetBytes: Int64
    public let recommendedModel: String

    public func pull(for name: String) -> RoachModelPull? { pulls.first { $0.name == name } }
    public var hasActivePulls: Bool { pulls.contains(where: \.isActive) }
}

extension RoachModelLibraryEntry {
    public static func displayOrder(_ models: [RoachModelLibraryEntry]) -> [RoachModelLibraryEntry] {
        models.sorted { left, right in
            if left.recommended != right.recommended { return left.recommended }
            if left.isCodeModel != right.isCodeModel { return left.isCodeModel }
            return left.size < right.size
        }
    }

    public var useLabel: String { isCodeModel ? "Code" : "Chat" }

    public var downloadSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: memoryNeeded, countStyle: .memory)
    }

    public var specLine: String {
        [useLabel, parameterSize, quantization, downloadSizeLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var makerLine: String {
        [publisher, license].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var fitLabel: String {
        switch fit {
        case "good": return "Runs well on this Mac"
        case "tight": return "Tight fit on this Mac"
        default: return "Too big for this Mac"
        }
    }

    public var fitDetail: String {
        switch fit {
        case "good": return "Uses about \(memoryLabel) of memory."
        case "tight": return "Uses about \(memoryLabel). Close other big apps while it runs."
        default: return "Needs about \(memoryLabel), more than this Mac can give a model."
        }
    }
}

extension RoachModelPull {
    public var progressLine: String {
        switch state {
        case "done": return "Downloaded and checked."
        case "stopped": return "Stopped. Downloading it again picks up where it stopped."
        case "failed": return "Didn't finish: \(message ?? "the download failed.")"
        default: break
        }
        switch phase {
        case "queued": return "Waiting for the download ahead of it."
        case "starting": return "Starting."
        case "retrying": return "The connection dropped. Trying again."
        case "verifying": return "Checking the download."
        case "installing": return "Installing."
        default:
            let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
            guard let total else { return "\(done) so far" }
            let whole = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let percent = Int(((fraction ?? 0) * 100).rounded(.down))
            return "\(done) of \(whole) · \(percent)%"
        }
    }
}
