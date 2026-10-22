import RoachNetCore

enum RoachClawModelState: Equatable {
    case ready
    case downloading
    case notDownloaded
    case notRunning

    static func resolve(serverReady: Bool, hosted: Bool, installed: Bool, pull: RoachModelPull?) -> RoachClawModelState
    {
        guard serverReady else { return .notRunning }
        if hosted || installed { return .ready }
        if pull?.isActive == true { return .downloading }
        return .notDownloaded
    }

    static func of(_ model: String, in status: RoachClawStatusResponse?, hosted: Bool) -> RoachClawModelState {
        guard let status else { return .notRunning }
        return resolve(
            serverReady: status.ready == true,
            hosted: hosted,
            installed: isInstalled(model, in: status),
            pull: status.modelPulls?.first { sameModel($0.name, model) }
        )
    }

    static func isInstalled(_ model: String, in status: RoachClawStatusResponse) -> Bool {
        if let known = status.defaultModelInstalled, let defaultModel = status.defaultModel,
            sameModel(model, defaultModel)
        {
            return known
        }
        return status.installedModels.contains { sameModel($0, model) }
    }

    static func sameModel(_ left: String, _ right: String) -> Bool {
        let wanted = normalized(left)
        return !wanted.isEmpty && wanted == normalized(right)
    }

    private static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : trimmed + ":latest"
    }

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .downloading: return "Downloading"
        case .notDownloaded: return "Not downloaded yet"
        case .notRunning: return "Not ready"
        }
    }

    var note: String? {
        switch self {
        case .ready: return nil
        case .downloading: return "downloading"
        case .notDownloaded: return "not downloaded yet"
        case .notRunning: return "not ready"
        }
    }

    var whereLabel: String {
        switch self {
        case .ready: return "On this Mac"
        case .downloading: return "Downloading to this Mac"
        case .notDownloaded: return "Not on this Mac yet"
        case .notRunning: return "Waiting for the model server"
        }
    }

    var fallbackDetail: String {
        switch self {
        case .ready: return "Local model answers first"
        case .downloading: return "Local model still downloading"
        case .notDownloaded: return "Local model not downloaded yet"
        case .notRunning: return "Local model still loading"
        }
    }

    var greeting: String {
        switch self {
        case .ready: return "Ask anything."
        case .downloading: return "The model is still downloading. Ask once it's here."
        case .notDownloaded: return "This chat's model isn't on this Mac yet. Download it in Settings › Models."
        case .notRunning: return "The model server is still starting."
        }
    }

    var devStatus: String {
        switch self {
        case .ready: return "Model ready"
        case .downloading: return "Model downloading"
        case .notDownloaded: return "Model not downloaded yet"
        case .notRunning: return "Local engine offline"
        }
    }
}
