import Foundation
import SwiftUI
import AppKit
import Darwin
import RoachNetCore
import RoachNetDesign

enum SetupStage: Int, CaseIterable, Identifiable {
    case welcome
    case machine
    case runtime
    case roachClaw
    case finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Start"
        case .machine: return "Machine"
        case .runtime: return "Runtime"
        case .roachClaw: return "RoachClaw"
        case .finish: return "Launch"
        }
    }

    var headline: String {
        switch self {
        case .welcome: return "Start the install."
        case .machine: return "Choose where RoachNet lives."
        case .runtime: return "Set the local stack."
        case .roachClaw: return "Pick the first AI model."
        case .finish: return "Open the real app."
        }
    }

    var detail: String {
        switch self {
        case .welcome: return "RoachNet stages the app, runtime, and first content before it hands the Mac back to you."
        case .machine: return "Keep the app, storage, and runtime under one roof so backup, repair, and cleanup stay predictable."
        case .runtime: return "Bring the working stack up inside RoachNet instead of scattering it across the Mac."
        case .roachClaw: return "Start with one reliable local model now. You can widen the lane later."
        case .finish: return "The stack is staged. Open RoachNet and get to work."
        }
    }
}

@MainActor
final class SetupController: ObservableObject {
    @Published var stage: SetupStage = .welcome
    @Published var config: RoachNetInstallerConfig = RoachNetRepositoryLocator.readConfig()
    @Published var setupState: RoachNetSetupState?
    @Published var statusLine: String = "Booting setup."
    @Published var errorLine: String?
    @Published var isBooting = true
    @Published var isBusy = false
    @Published var primaryActionCoolingDown = false

    private var allowAutomaticFinishAdvance = true
    private var startedInstallInCurrentSession = false
    private var scheduledAutomaticExit = false
    private var process: Process?
    private var readyFileURL: URL?
    private var serverURL: URL?
    private var pollTask: Task<Void, Never>?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var backendScriptURL: URL?
    private var primaryActionCooldownTask: Task<Void, Never>?
    private var installRequestSentAt: Date?

    var stageTitles: [String] { SetupStage.allCases.map(\.title) }
    var canGoBack: Bool { stage != .welcome && !isBusy }

    init() {
        Task {
            await boot()
        }
    }

    func shutdown() {
        pollTask?.cancel()
        primaryActionCooldownTask?.cancel()
        terminateBackendProcess()

        if let readyFileURL {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
    }

    func boot() async {
        isBooting = true
        errorLine = nil
        statusLine = "Bringing the setup lane online."

        do {
            try await ensureBackend()
            startPolling()
            statusLine = "Setup lane ready."
            isBooting = false

            do {
                try await refreshState()
                statusLine = "Setup is ready."
            } catch {
                errorLine = describe(error)
                statusLine = "Setup service unavailable."
            }
        } catch {
            errorLine = describe(error)
            statusLine = "Setup service unavailable."
            isBooting = false
        }
    }

    func back() {
        guard let previous = SetupStage(rawValue: stage.rawValue - 1) else { return }
        primaryActionCooldownTask?.cancel()
        primaryActionCoolingDown = false
        allowAutomaticFinishAdvance = false
        stage = previous
    }

    func beginPrimaryAction() -> Bool {
        guard !(primaryActionCoolingDown || isBooting || isBusy) else {
            return false
        }

        primaryActionCoolingDown = true
        return true
    }

    func primaryAction() async {
        allowAutomaticFinishAdvance = true
        switch stage {
        case .welcome:
            scheduleStageTransition(to: .machine)
        case .machine:
            if await refreshAction() {
                scheduleStageTransition(to: .runtime)
            } else {
                primaryActionCoolingDown = false
            }
        case .runtime:
            allowAutomaticFinishAdvance = false
            scheduleStageTransition(to: .roachClaw)
        case .roachClaw:
            await installAction()
            primaryActionCoolingDown = false
        case .finish:
            await launchAction()
            primaryActionCoolingDown = false
        }
    }

    @discardableResult
    func refreshAction() async -> Bool {
        do {
            try await persistConfig()
            try await refreshState()
            statusLine = "Setup state refreshed."
            return true
        } catch {
            errorLine = describe(error)
            return false
        }
    }

    func chooseStorageFolder() {
        let currentPath = config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath

        let panel = NSOpenPanel()
        panel.title = "Choose RoachNet Content Folder"
        panel.message = "Pick the folder RoachNet should use for maps, archives, downloads, and local content."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()

        guard panel.runModal() == .OK, let selectedPath = panel.url?.path else {
            return
        }

        config.storagePath = selectedPath
        statusLine = "Content folder updated."
    }

    func chooseInstallFolder() {
        let currentPath = config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let previousInstallPath = currentPath
        let previousDefaultStoragePath = RoachNetRepositoryLocator.defaultStoragePath(installPath: previousInstallPath)

        let panel = NSOpenPanel()
        panel.title = "Choose RoachNet Install Root"
        panel.message = "Pick the folder RoachNet should use as its contained root. The app, runtime, and default storage stay grouped there."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()

        guard panel.runModal() == .OK, let selectedPath = panel.url?.path else {
            return
        }

        config.installPath = selectedPath
        config.installedAppPath = RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: selectedPath)

        if config.storagePath.isEmpty || config.storagePath == previousDefaultStoragePath {
            config.storagePath = RoachNetRepositoryLocator.defaultStoragePath(installPath: selectedPath)
        }

        statusLine = "Install root updated."
    }

    func startRuntimeAction() async {
        guard config.useDockerContainerization else {
            statusLine = "Docker containerization is off for this install."
            return
        }

        guard !isBusy else { return }
        isBusy = true
        errorLine = nil
        statusLine = "Starting the contained runtime."

        do {
            try await persistConfig()
            let _: SimpleOKResponse = try await request(
                path: "/api/container-runtime/start",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            try await refreshState()
            statusLine = "Contained runtime start requested."
        } catch {
            errorLine = describe(error)
        }

        isBusy = false
    }

    func installAction() async {
        guard !isBusy else { return }
        isBusy = true
        errorLine = nil
        statusLine = "Staging RoachNet."
        startedInstallInCurrentSession = true

        do {
            try await persistConfig()
            let _: SimpleOKResponse = try await request(
                path: "/api/install",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            installRequestSentAt = Date()
            startPolling()
            statusLine = "Staging the install."
        } catch {
            installRequestSentAt = nil
            startedInstallInCurrentSession = false
            errorLine = describe(error)
            isBusy = false
        }
    }

    func launchAction() async {
        guard !isBusy else { return }
        isBusy = true
        errorLine = nil
        statusLine = "Opening the real shell."

        do {
            try await persistConfig()
            let targetPath = config.installedAppPath.isEmpty
                ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: config.installPath)
                : config.installedAppPath
            if FileManager.default.fileExists(atPath: targetPath) {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: targetPath),
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            }
            Task { [config] in
                _ = try? await request(
                    path: "/api/launch",
                    method: "POST",
                    body: config,
                    as: SimpleOKResponse.self
                )
            }
            statusLine = "RoachNet is open."
            for window in NSApp.windows {
                window.close()
            }
            NSApp.terminate(nil)
        } catch {
            errorLine = describe(error)
        }

        isBusy = false
    }

    private func startPolling() {
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await refreshState()
                } catch {
                    await MainActor.run {
                        self.errorLine = self.describe(error)
                    }
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func persistConfig() async throws {
        try RoachNetRepositoryLocator.writeConfig(config)
        let state = try await request(path: "/api/config", method: "POST", body: config, as: ConfigResponse.self)
        config = state.config
    }

    private func refreshState() async throws {
        let state = try await request(
            path: "/api/state",
            method: "GET",
            queryItems: stateQueryItems(),
            as: RoachNetSetupState.self
        )
        setupState = state
        config = state.config

        if state.activeTask?.status == "running" {
            statusLine = state.activeTask?.phase ?? "Setup running."
            isBusy = true
            errorLine = nil
        } else {
            isBusy = false
            if state.lastCompletedTask?.status == "failed" {
                startedInstallInCurrentSession = false
                installRequestSentAt = nil
                errorLine = state.lastCompletedTask?.error
                statusLine = "Setup needs attention."
            } else if state.lastCompletedTask?.status == "completed" {
                errorLine = nil
            }
        }

        let hasPreparedWorkspace = state.installLooksReady || state.config.setupCompletedAt != nil
        let completedInstallInCurrentSession = didCompleteCurrentInstall(using: state.lastCompletedTask)
        let installCompleted =
            state.lastCompletedTask?.status == "completed"
            || (state.nativeApp.installed && hasPreparedWorkspace)
        let canAdvanceToFinishFromCurrentStage = stage.rawValue >= SetupStage.roachClaw.rawValue

        if completedInstallInCurrentSession, allowAutomaticFinishAdvance, canAdvanceToFinishFromCurrentStage {
            stage = .finish
            statusLine = "Install complete."

            if config.autoLaunch,
               state.nativeApp.installed {
                scheduleAutomaticExitIfNeeded()
            }
        } else if stage == .finish && !installCompleted {
            stage = .roachClaw
            scheduledAutomaticExit = false
        }
    }

    private func stateQueryItems() -> [URLQueryItem] {
        guard Self.shouldApplyDraftStateOverrides(
            startedInstallInCurrentSession: startedInstallInCurrentSession,
            activeTaskStatus: setupState?.activeTask?.status
        ) else {
            return []
        }

        let installPath = config.installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let installedAppPath = config.installedAppPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath)
            : config.installedAppPath
        let storagePath = config.storagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: installPath)
            : config.storagePath

        return [
            URLQueryItem(name: "installPath", value: installPath),
            URLQueryItem(name: "installedAppPath", value: installedAppPath),
            URLQueryItem(name: "storagePath", value: storagePath),
            URLQueryItem(name: "installProfile", value: config.installProfile),
            URLQueryItem(name: "useDockerContainerization", value: config.useDockerContainerization ? "true" : "false"),
            URLQueryItem(name: "installRoachClaw", value: config.installRoachClaw ? "true" : "false"),
            URLQueryItem(name: "roachClawDefaultModel", value: config.roachClawDefaultModel),
            URLQueryItem(name: "companionEnabled", value: config.companionEnabled ? "true" : "false"),
            URLQueryItem(name: "companionHost", value: config.companionHost),
            URLQueryItem(name: "companionPort", value: String(config.companionPort)),
            URLQueryItem(name: "companionToken", value: config.companionToken),
            URLQueryItem(name: "companionAdvertisedURL", value: config.companionAdvertisedURL),
            URLQueryItem(name: "autoLaunch", value: config.autoLaunch ? "true" : "false"),
            URLQueryItem(name: "releaseChannel", value: config.releaseChannel),
            URLQueryItem(name: "distributedInferenceBackend", value: config.distributedInferenceBackend),
            URLQueryItem(name: "exoBaseUrl", value: config.exoBaseUrl),
            URLQueryItem(name: "exoModelId", value: config.exoModelId),
        ]
    }

    nonisolated static func shouldApplyDraftStateOverrides(
        startedInstallInCurrentSession: Bool,
        activeTaskStatus: String?
    ) -> Bool {
        guard !startedInstallInCurrentSession else {
            return false
        }

        return activeTaskStatus != "running"
    }

    private func scheduleStageTransition(to nextStage: SetupStage) {
        primaryActionCooldownTask?.cancel()

        primaryActionCooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(10))
            self?.stage = nextStage
            try? await Task.sleep(for: .milliseconds(350))
            self?.primaryActionCoolingDown = false
        }
    }

    private func didCompleteCurrentInstall(using lastCompletedTask: RoachNetSetupState.TaskState?) -> Bool {
        guard
            startedInstallInCurrentSession,
            let installRequestSentAt,
            lastCompletedTask?.status == "completed"
        else {
            return false
        }

        let formatter = ISO8601DateFormatter()
        let recordedDates = [lastCompletedTask?.startedAt, lastCompletedTask?.finishedAt]
            .compactMap { $0 }
            .compactMap(formatter.date(from:))

        guard let newestRecordedDate = recordedDates.max() else {
            return false
        }

        return newestRecordedDate >= installRequestSentAt.addingTimeInterval(-1)
    }

    private func scheduleAutomaticExitIfNeeded() {
        guard !scheduledAutomaticExit else { return }
        scheduledAutomaticExit = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            for window in NSApp.windows {
                window.close()
            }
            NSApp.terminate(nil)
        }
    }

    private func ensureBackend() async throws {
        if serverURL != nil {
            return
        }

        if let override = ProcessInfo.processInfo.environment["ROACHNET_SETUP_URL"], let url = URL(string: override) {
            serverURL = url
            return
        }

        let setupWorkspaceRoot = preferredSetupWorkspaceRoot()
        setenv("ROACHNET_SETUP_WORK_ROOT", setupWorkspaceRoot, 1)

        let repoRoot = await Task.detached(priority: .userInitiated) {
            RoachNetRepositoryLocator.repositoryRoot()
        }.value

        guard let repoRoot else {
            throw NSError(domain: "RoachNetSetup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not locate the RoachNet repository root for the setup backend."
            ])
        }

        let scriptURL = repoRoot.appendingPathComponent("scripts/run-roachnet-setup.mjs")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(domain: "RoachNetSetup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing setup backend at \(scriptURL.path)."
            ])
        }
        backendScriptURL = scriptURL
        Self.terminateSetupBackends(scriptURL: scriptURL)

        let readyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roachnet-setup-\(UUID().uuidString).json")
        self.readyFileURL = readyFileURL

        let node = RoachNetRepositoryLocator.preferredNodeBinary()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let resolvedNodeBinary = node == "/usr/bin/env" ? "/usr/bin/env" : node
        process.executableURL = URL(fileURLWithPath: resolvedNodeBinary)
        process.arguments = node == "/usr/bin/env" ? ["node", scriptURL.path] : [scriptURL.path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["ROACHNET_SETUP_NO_BROWSER"] = "1"
        environment["ROACHNET_SETUP_READY_FILE"] = readyFileURL.path
        environment["ROACHNET_REPO_ROOT"] = repoRoot.path
        environment["ROACHNET_SETUP_WORK_ROOT"] = setupWorkspaceRoot
        if let installerAssets = RoachNetRepositoryLocator.bundledInstallerAssetsDirectory() {
            environment["ROACHNET_SETUP_APP_BUNDLE"] = installerAssets
                .appendingPathComponent("setup-assets.marker")
                .path
        }
        process.environment = environment

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if
                let data = try? Data(contentsOf: readyFileURL),
                let ready = try? JSONDecoder().decode(ReadyFile.self, from: data),
                let url = URL(string: ready.url)
            {
                serverURL = url
                return
            }

            if !process.isRunning {
                throw NSError(domain: "RoachNetSetup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                        fallback: "The native installer could not keep the setup backend running.",
                        includePipeOutput: true
                    )
                ])
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(domain: "RoachNetSetup", code: 3, userInfo: [
                NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                    fallback: "The native installer could not boot the setup service before the local timeout.",
                    includePipeOutput: false
                )
            ])
    }

    private func terminateBackendProcess() {
        let childPid = process?.processIdentifier

        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2.5)

            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        if let backendScriptURL {
            Self.terminateSetupBackends(scriptURL: backendScriptURL, excluding: childPid)
        }

        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        serverURL = nil
    }

    private static func terminateSetupBackends(scriptURL: URL, excluding excludedPid: Int32? = nil) {
        let scriptName = scriptURL.lastPathComponent
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fal", scriptName]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return
        }

        let rawOutput = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let matchingPids = rawOutput
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard
                    trimmedLine.contains(scriptName),
                    trimmedLine.localizedCaseInsensitiveContains("roachnet")
                else {
                    return nil
                }

                let parts = trimmedLine.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard let firstPart = parts.first, let pid = Int32(firstPart) else {
                    return nil
                }

                if pid == ProcessInfo.processInfo.processIdentifier || pid == excludedPid {
                    return nil
                }

                return pid
            }

        guard !matchingPids.isEmpty else {
            return
        }

        for pid in matchingPids {
            kill(pid, SIGTERM)
        }

        usleep(300_000)

        for pid in matchingPids {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            timeout: requestTimeout(for: path),
            queryItems: queryItems,
            body: Optional<AnyEncodable>.none,
            as: type
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: some Encodable,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await performRequest(
            path: path,
            method: method,
            timeout: requestTimeout(for: path),
            body: AnyEncodable(body),
            as: type
        )
    }

    private func performRequest<Response: Decodable>(
        path: String,
        method: String,
        timeout: TimeInterval,
        queryItems: [URLQueryItem] = [],
        body: AnyEncodable?,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        guard let base = serverURL else {
            throw NSError(domain: "RoachNetSetup", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The setup backend is not running."
            ])
        }

        var requestURL = base.appending(path: path)
        if !queryItems.isEmpty,
           var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        {
            components.queryItems = queryItems
            if let resolvedURL = components.url {
                requestURL = resolvedURL
            }
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = timeout

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut && path == "/api/container-runtime/start" {
            throw NSError(domain: "RoachNetSetup", code: 408, userInfo: [
                NSLocalizedDescriptionKey: "RoachNet Setup waited too long for the contained Docker lane to answer. Docker may still be warming up on this Mac. Try the runtime step again in a moment."
            ])
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500

        if (200..<300).contains(statusCode) {
            return try JSONDecoder().decode(Response.self, from: data)
        }

        if let apiError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw NSError(domain: "RoachNetSetup", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: apiError.error
            ])
        }

        throw NSError(domain: "RoachNetSetup", code: statusCode, userInfo: [
            NSLocalizedDescriptionKey: "Request failed with status \(statusCode)."
        ])
    }

    private func requestTimeout(for path: String) -> TimeInterval {
        switch path {
        case "/api/container-runtime/start":
            return 240
        default:
            return 120
        }
    }

    private func describe(_ error: Error) -> String {
        if error is DecodingError {
            return "RoachNet Setup hit a bad installer response. Try refreshing the step."
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("couldn’t be read because it isn’t in the correct format")
            || description.localizedCaseInsensitiveContains("isn’t in the correct format")
        {
            return "RoachNet Setup hit a bad installer response. Try refreshing the step."
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .timedOut:
                return "RoachNet Setup couldn't reach the local setup service. Try again in a moment."
            default:
                break
            }
        }

        if description.localizedCaseInsensitiveContains("needs about")
            && description.localizedCaseInsensitiveContains("free on the selected install volume")
        {
            return description
        }

        if description.localizedCaseInsensitiveContains("no space left on device")
            || description.localizedCaseInsensitiveContains("enospc")
        {
            return "RoachNet ran out of disk space while staging the contained install. Free up more space, choose a roomier install root, or turn off Install RoachClaw for the first pass."
        }

        if description.localizedCaseInsensitiveContains("reading 'includes'")
            || description.localizedCaseInsensitiveContains("reading \\\"includes\\\"")
        {
                return "RoachNet Setup hit a bad package check while staging the contained tools. Retry the install with the rebuilt bundle."
        }

        if description.localizedCaseInsensitiveContains("npm error")
            || description.localizedCaseInsensitiveContains("npm install")
        {
            return "RoachNet Setup couldn't finish staging one of the contained tool bundles. Retry the install. If you only need the shell first, turn off Install RoachClaw and finish the AI lane after launch."
        }

        if description.localizedCaseInsensitiveContains("timed out")
            && description.localizedCaseInsensitiveContains("runtime")
        {
            return "RoachNet Setup waited too long for the contained runtime to answer. Retry the install. The next build should keep this lane warmer on cold Macs."
        }

        return description
    }

    private func makeBackendBootFailureMessage(fallback: String, includePipeOutput: Bool) -> String {
        guard includePipeOutput else {
            return fallback
        }

        let details = [
            stderrPipe.map(Self.readPipeOutput(from:)),
            stdoutPipe.map(Self.readPipeOutput(from:)),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        return details.map { "\(fallback) \($0)" } ?? fallback
    }

    private static func readPipeOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func preferredSetupWorkspaceRoot() -> String {
        let candidateInstallPath = config.installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath

        var candidates: [URL] = [
            URL(fileURLWithPath: RoachNetRepositoryLocator.defaultSetupWorkspaceRoot(installPath: candidateInstallPath))
        ]

        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeAvailableCapacityForImportantUsageKey, .isWritableKey, .volumeIsReadOnlyKey],
            options: [.skipHiddenVolumes]
        ) {
            for volumeURL in mountedVolumes {
                candidates.append(volumeURL.appendingPathComponent(".roachnet-setup", isDirectory: true))
            }
        }

        let deduplicatedCandidates = Array(
            Dictionary(grouping: candidates, by: { $0.standardizedFileURL.path }).values.compactMap(\.first)
        )

        let bestCandidate = deduplicatedCandidates.max { lhs, rhs in
            availableCapacity(for: lhs) < availableCapacity(for: rhs)
        }

        return bestCandidate?.standardizedFileURL.path
            ?? URL(fileURLWithPath: RoachNetRepositoryLocator.defaultSetupWorkspaceRoot(installPath: candidateInstallPath)).standardizedFileURL.path
    }

    private func availableCapacity(for workspaceURL: URL) -> Int64 {
        let probeURL = workspaceURL.deletingLastPathComponent()
        do {
            let values = try probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .isWritableKey, .volumeIsReadOnlyKey])
            if values.volumeIsReadOnly == true || values.isWritable == false {
                return 0
            }

            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
        } catch {
            return 0
        }

        return 0
    }
}

private struct SimpleOKResponse: Decodable {
    let ok: Bool
}

private struct ReadyFile: Decodable {
    let url: String
}

private struct ErrorResponse: Decodable {
    let error: String
}

private struct ConfigResponse: Decodable {
    let ok: Bool
    let config: RoachNetInstallerConfig
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        self.encodeImpl = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

@main
struct RoachNetSetupApp: App {
    @NSApplicationDelegateAdaptor(RoachNetSetupAppDelegate.self) private var appDelegate
    @StateObject private var controller: SetupController

    @MainActor
    init() {
        let controller = SetupController()
        _controller = StateObject(wrappedValue: controller)
        RoachNetSetupAppDelegate.bootstrapController = controller
    }

    var body: some Scene {
        WindowGroup("RoachNet Setup", id: "main") {
            SetupRootView(controller: controller)
                .background(SetupWindowConfigurator())
                .frame(minWidth: 760, idealWidth: 980, minHeight: 580, idealHeight: 740)
                .onAppear {
                    appDelegate.controller = controller
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class RoachNetSetupAppDelegate: NSObject, NSApplicationDelegate {
    static var bootstrapController: SetupController?

    var controller: SetupController?
    private var fallbackWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        clearSavedState()
        NSApp.setActivationPolicy(.regular)
        controller = controller ?? Self.bootstrapController
        bringPrimaryWindowForward()
        scheduleFallbackWindowIfNeeded()
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringPrimaryWindowForward()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shutdown()
        return .terminateNow
    }

    private func bringPrimaryWindowForward(retriesRemaining: Int = 18) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) ?? NSApp.windows.first {
                self?.configure(window: window)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else if retriesRemaining > 0 {
                self?.bringPrimaryWindowForward(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    private func scheduleFallbackWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard !NSApp.windows.contains(where: { $0.isVisible }) else { return }
            self.createFallbackWindow()
        }
    }

    private func createFallbackWindow() {
        guard fallbackWindowController == nil else { return }
        guard let controller = controller ?? Self.bootstrapController else { return }

        let contentView = SetupRootView(controller: controller)
            .frame(minWidth: 760, idealWidth: 980, minHeight: 580, idealHeight: 740)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RoachNet Setup"
        window.contentViewController = hostingController
        configure(window: window)
        window.center()

        let windowController = NSWindowController(window: window)
        fallbackWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func configure(window: NSWindow) {
        window.minSize = NSSize(width: 760, height: 580)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.isRestorable = false
    }

    private func clearSavedState() {
        let savedStatePath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("com.roachwares.roachnet.setup.savedState", isDirectory: true)
            .path

        try? FileManager.default.removeItem(atPath: savedStatePath)
    }
}

private struct SetupRootView: View {
    @ObservedObject var controller: SetupController

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = proxy.size.width < 920 ? 14.0 : 20.0
            let verticalPadding = proxy.size.height < 720 ? 18.0 : 30.0

            ZStack {
                RoachBackground()

                VStack(spacing: 18) {
                    chromeBar(width: proxy.size.width - (horizontalPadding * 2))
                    mainCard
                }
                .frame(maxWidth: 1120, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, verticalPadding)
                .padding(.bottom, 18)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: controller.stage)
    }

    private func chromeBar(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            ZStack {
                HStack {
                    Spacer()
                    RoachTag("Apple Silicon", accent: RoachPalette.magenta)
                }

                setupTitleLockup
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, width < 920 ? 64 : 112)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                setupTitleLockup
                RoachTag("Apple Silicon", accent: RoachPalette.magenta)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var mainCard: some View {
        RoachPanel {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        progressHeader
                        stageHero
                        stageContent

                        if showStatusSection {
                            statusSection
                        }
                    }
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(RoachPalette.border.opacity(0.72))
                    .frame(height: 1)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)

                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var setupTitleLockup: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                RoachOrbitMark()
                    .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 3) {
                    Text("RoachNet Setup")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    Text("Contained install for this Mac")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                RoachOrbitMark()
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 3) {
                    Text("RoachNet Setup")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(RoachPalette.text)
                    Text("Contained install for this Mac")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Setup Flow")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RoachPalette.muted)

                Spacer()

                Text("\(controller.stage.rawValue + 1) / \(SetupStage.allCases.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                RoachStageStrip(titles: controller.stageTitles, activeIndex: controller.stage.rawValue)
            }
        }
    }

    private var stageHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                stageHeroCopy

                Spacer(minLength: 0)

                stageHeroGlyph
            }

            VStack(alignment: .leading, spacing: 18) {
                stageHeroCopy

                stageHeroGlyph
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch controller.stage {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachFeatureTile(
                        "Machine",
                        title: "Check this Mac",
                        detail: "RoachNet reads the machine and only stages what this install still needs.",
                        systemName: "desktopcomputer",
                        accent: RoachPalette.green
                    )
                    RoachFeatureTile(
                        "Runtime",
                        title: "Stage the stack",
                        detail: "The runtime and contained services are staged here instead of assumed.",
                        systemName: "server.rack",
                        accent: RoachPalette.magenta
                    )
                    RoachFeatureTile(
                        "Launch",
                        title: "Open RoachNet",
                        detail: "Move straight into the real shell once storage, runtime, and the first AI lane are in place.",
                        systemName: "sparkles",
                        accent: RoachPalette.cyan
                    )
                }
            }

        case .machine:
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Install Root", value: installRootLabel(controller.config.installPath))
                    RoachInfoPill(title: "App Target", value: appTargetLabel(controller.config.installedAppPath))
                    RoachInfoPill(
                        title: "Content Folder",
                        value: contentFolderLabel(
                            controller.config.storagePath.isEmpty
                                ? RoachNetRepositoryLocator.defaultStoragePath(installPath: controller.config.installPath)
                                : controller.config.storagePath
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    SetupNativeButton(title: "Choose Install Root", role: .secondary) {
                        controller.chooseInstallFolder()
                    }

                    SetupNativeButton(title: "Choose Content Folder", role: .secondary) {
                        controller.chooseStorageFolder()
                    }

                    Text("You can change this later from Runtime.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    ForEach(machineRows, id: \.title) { row in
                        RoachInsetPanel {
                            RoachStatusRow(title: row.title, value: row.value, accent: row.accent)
                        }
                    }
                }
            }

        case .runtime:
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Runtime Mode", value: runtimeModeValue)
                    RoachInfoPill(title: "Container Runtime", value: runtimeValue)
                    RoachInfoPill(title: "Services", value: servicesValue)
                    RoachInfoPill(
                        title: "Storage",
                        value: contentFolderLabel(
                            controller.config.storagePath.isEmpty
                                ? RoachNetRepositoryLocator.defaultStoragePath(installPath: controller.config.installPath)
                                : controller.config.storagePath
                        )
                    )
                }

                RoachInsetPanel {
                    Toggle(isOn: $controller.config.useDockerContainerization) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use Docker containerization")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Leave this off for the contained Apple Silicon path. Turn it on only if you want Docker-backed support services.")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                    .toggleStyle(.switch)
                }

                RoachInsetPanel {
                    Toggle(isOn: $controller.config.companionEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable RoachTail pairing")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Leave the private device lane on if you want iPhone and iPad builds to pair with a one-time join code.")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                    .toggleStyle(.switch)
                }

                if controller.config.useDockerContainerization {
                    SetupNativeButton(title: "Start Runtime Now", role: .secondary, isEnabled: !controller.isBusy) {
                        Task { await controller.startRuntimeAction() }
                    }
                }
            }

        case .roachClaw:
            VStack(alignment: .leading, spacing: 16) {
                RoachInlineField(title: "Default model", value: $controller.config.roachClawDefaultModel, placeholder: "qwen2.5-coder:1.5b")

                RoachInsetPanel {
                    Toggle(isOn: $controller.config.installRoachClaw) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Install RoachClaw")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                            Text("Stage the first local AI lane now so chat is ready when the shell opens.")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(RoachPalette.muted)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

        case .finish:
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        RoachTag("RoachNet ready")
                        if controller.config.installRoachClaw {
                            RoachTag(controller.config.roachClawDefaultModel, accent: RoachPalette.magenta)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        RoachTag("RoachNet ready")
                        if controller.config.installRoachClaw {
                            RoachTag(controller.config.roachClawDefaultModel, accent: RoachPalette.magenta)
                        }
                    }
                }

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Main App", value: controller.setupState?.nativeApp.installed == true ? "Installed" : "Ready")
                    RoachInfoPill(title: "RoachClaw", value: controller.config.installRoachClaw ? "Aligned" : "Skipped")
                    RoachInfoPill(title: "Runtime", value: servicesValue)
                    RoachInfoPill(title: "RoachTail", value: controller.config.companionEnabled ? "Armed" : "Off")
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorLine = controller.errorLine {
                RoachNotice(title: "Setup needs attention", detail: errorLine)
            } else if controller.isBooting {
                RoachNotice(title: "Booting setup", detail: "Starting the local setup service.", accent: RoachPalette.green, systemName: "arrow.triangle.2.circlepath")
            } else {
                RoachNotice(title: "Installer status", detail: controller.statusLine, accent: RoachPalette.green, systemName: "checkmark.circle.fill")
            }

            if let logs = controller.setupState?.activeTask?.logs, !logs.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        RoachKicker("Recent setup log")
                        ForEach(Array(logs.suffix(2).enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(RoachPalette.muted)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            SetupNativeButton(title: "Back", role: .secondary, isEnabled: controller.canGoBack) {
                controller.back()
            }

            Spacer(minLength: 12)

            SetupNativeButton(
                title: primaryTitle,
                role: .primary,
                isEnabled: !(controller.isBooting || controller.isBusy || controller.primaryActionCoolingDown),
                isDefaultAction: true,
                minWidth: 138
            ) {
                guard controller.beginPrimaryAction() else { return }
                Task { await controller.primaryAction() }
            }
            .id("primary-\(controller.stage.rawValue)")
        }
    }

    private func welcomeCard(title: String, detail: String) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var showStatusSection: Bool {
        controller.isBooting
            || controller.errorLine != nil
            || controller.isBusy
            || !(controller.setupState?.activeTask?.logs?.isEmpty ?? true)
    }

    private var primaryTitle: String {
        switch controller.stage {
        case .roachClaw:
            return controller.isBusy ? "Installing..." : "Install RoachNet"
        case .finish:
            return "Open RoachNet"
        default:
            return "Continue"
        }
    }

    private var machineRows: [(title: String, value: String, accent: Color)] {
        let dependencies = controller.setupState?.dependencies ?? []

        if dependencies.isEmpty {
            return [
                ("Container Runtime", runtimeValue, RoachPalette.green),
                ("Services", servicesValue, controller.setupState?.installLooksReady == true ? RoachPalette.green : RoachPalette.warning),
            ]
        }

        return dependencies.prefix(4).map { dependency in
            let status: String
            let accent: Color

            if dependency.detectionPending == true {
                status = "Checking"
                accent = RoachPalette.muted
            } else {
                status = dependency.available ? "Ready" : (dependency.required ? "Needed" : "Optional")
                accent = dependency.available ? RoachPalette.success : (dependency.required ? RoachPalette.warning : RoachPalette.muted)
            }

            return (dependency.label, status, accent)
        }
    }

    private var runtimeValue: String {
        if !controller.config.useDockerContainerization {
            return "Not selected"
        }
        if controller.setupState?.containerRuntime.detectionPending == true {
            return "Checking"
        }
        if controller.setupState?.containerRuntime.ready == true {
            return "Ready"
        }
        if controller.setupState?.containerRuntime.available == true {
            return "Detected"
        }
        return "Needs Setup"
    }

    private var runtimeModeValue: String {
        controller.config.useDockerContainerization ? "Docker" : "Contained Local"
    }

    private var servicesValue: String {
        if controller.setupState?.installLooksReady == true {
            return "Ready"
        }
        if controller.setupState?.activeTask?.status == "running" {
            return "Starting"
        }
        return "Pending"
    }

    private func installRootLabel(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "RoachNet root"
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        if lastComponent.isEmpty || lastComponent.localizedCaseInsensitiveContains("roachnet") {
            return "RoachNet root"
        }

        return "\(lastComponent) / RoachNet"
    }

    private func appTargetLabel(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "RoachNet.app"
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastComponent.isEmpty ? "RoachNet.app" : lastComponent
    }

    private func contentFolderLabel(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "RoachNet storage"
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        if lastComponent.isEmpty || lastComponent.localizedCaseInsensitiveContains("storage") {
            return "RoachNet storage"
        }

        return lastComponent
    }

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 208), spacing: 12, alignment: .top)]
    }

    private var stageHeroCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoachKicker(controller.stage.title)
            Text(controller.stage.headline)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(RoachPalette.text)
                .minimumScaleFactor(0.80)
                .fixedSize(horizontal: false, vertical: true)
            Text(controller.stage.detail)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stageHeroGlyph: some View {
        if controller.stage == .welcome || controller.stage == .finish {
            RoachOrbitMark()
                .frame(width: 104, height: 104)
        } else {
            Image(systemName: stageSystemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(stageAccent)
                .frame(width: 96, height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(stageAccent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(stageAccent.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private var stageSystemImage: String {
        switch controller.stage {
        case .welcome:
            return "sparkles"
        case .machine:
            return "shippingbox.fill"
        case .runtime:
            return "server.rack"
        case .roachClaw:
            return "brain.head.profile"
        case .finish:
            return "checkmark.circle.fill"
        }
    }

    private var stageAccent: Color {
        switch controller.stage {
        case .welcome, .finish:
            return RoachPalette.magenta
        case .machine:
            return RoachPalette.bronze
        case .runtime:
            return RoachPalette.green
        case .roachClaw:
            return RoachPalette.cyan
        }
    }

}

private struct SetupWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        @MainActor
        func configure(window: NSWindow) {
            let minimumSize = NSSize(width: 760, height: 580)
            let preferredSize = NSSize(width: 980, height: 740)
            window.minSize = minimumSize
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.tabbingMode = .disallowed
            window.isMovableByWindowBackground = false
            window.isRestorable = false

            let currentSize = window.frame.size
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let isOffscreen = screenFrame.map { !$0.intersects(window.frame) } ?? false

            if currentSize.width < minimumSize.width || currentSize.height < minimumSize.height || isOffscreen {
                var frame = window.frame
                frame.size.width = max(preferredSize.width, minimumSize.width)
                frame.size.height = max(preferredSize.height, minimumSize.height)
                if let screenFrame {
                    frame.origin.x = screenFrame.midX - (frame.size.width / 2)
                    frame.origin.y = screenFrame.midY - (frame.size.height / 2)
                }
                window.setFrame(frame, display: true, animate: false)
            }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = SetupWindowAttachmentView(frame: .zero)
        view.onWindowAvailable = { window in
            Task { @MainActor in
                context.coordinator.configure(window: window)
            }
        }
        DispatchQueue.main.async { [weak view] in
            view?.notifyIfWindowAvailable()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let attachmentView = nsView as? SetupWindowAttachmentView else { return }
        attachmentView.onWindowAvailable = { window in
            Task { @MainActor in
                context.coordinator.configure(window: window)
            }
        }
        attachmentView.notifyIfWindowAvailable()
    }
}

private final class SetupWindowAttachmentView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfWindowAvailable()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.notifyIfWindowAvailable()
        }
    }

    func notifyIfWindowAvailable() {
        guard let window else { return }
        onWindowAvailable?(window)
    }
}

private enum SetupNativeButtonRole {
    case primary
    case secondary
}

private struct SetupNativeButton: View {
    let title: String
    let role: SetupNativeButtonRole
    var isEnabled: Bool = true
    var isDefaultAction: Bool = false
    var minWidth: CGFloat = 112
    let action: () -> Void

    var body: some View {
        let label = Text(title)
            .frame(minWidth: minWidth)

        let base = Group {
            if role == .primary {
                Button(action: action) {
                    label
                }
                .buttonStyle(RoachPrimaryButtonStyle())
            } else {
                Button(action: action) {
                    label
                }
                .buttonStyle(RoachSecondaryButtonStyle())
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.62)

        if isDefaultAction {
            base.keyboardShortcut(.defaultAction)
        } else {
            base
        }
    }
}
