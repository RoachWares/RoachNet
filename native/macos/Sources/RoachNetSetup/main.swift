import AppKit
import Darwin
import Foundation
import RoachNetCore
import RoachNetDesign
import SwiftUI

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
        case .runtime: return "Set up the runtime."
        case .roachClaw: return "Pick the first AI model."
        case .finish: return "Open RoachNet."
        }
    }

    var detail: String {
        switch self {
        case .welcome:
            return
                "By default, RoachNet Setup puts the app in ~/RoachNet/app and your data in ~/RoachNet/storage. It doesn't install Node, Docker, Ollama or anything else."
        case .machine:
            return
                "The app, the runtime and your data stay together in one folder, so backing up, repairing or removing RoachNet happens in one place. To keep your data on another drive, choose a different content folder."
        case .runtime:
            return "RoachNet runs its local services from its own folder instead of installing them across the Mac."
        case .roachClaw:
            return
                "Pick the model RoachClaw starts with, plus any others you want. RoachNet downloads them when it first opens. Settings › Models adds more later."
        case .finish: return "Once RoachNet is installed, open it and start from Home."
        }
    }
}

@MainActor
final class SetupController: ObservableObject {
    @Published var stage: SetupStage = .welcome
    @Published var config: RoachNetInstallerConfig = RoachNetRepositoryLocator.readConfig()
    @Published var setupState: RoachNetSetupState?
    @Published var statusLine: String = "Starting the setup service."
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
    private var backendOutputTail: [String] = []

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
        statusLine = "Starting the setup service."

        do {
            try await ensureBackend()
            startPolling()
            statusLine = "Setup service ready."
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
            statusLine = "Status refreshed."
            return true
        } catch {
            errorLine = describe(error)
            return false
        }
    }

    func chooseStorageFolder() {
        let currentPath =
            config.storagePath.isEmpty
            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: config.installPath)
            : config.storagePath

        let panel = NSOpenPanel()
        panel.title = "Choose a folder for RoachNet content"
        panel.message = "Pick the folder RoachNet should use for maps, archives, downloads, and local content."
        panel.prompt = "Use folder"
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
        let currentPath =
            config.installPath.isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let previousInstallPath = currentPath
        let previousDefaultStoragePath = RoachNetRepositoryLocator.defaultStoragePath(installPath: previousInstallPath)

        let panel = NSOpenPanel()
        panel.title = "Choose where to install RoachNet"
        panel.message =
            "Pick the folder RoachNet installs into. The app and the runtime go there, and so does your data unless you choose a separate content folder."
        panel.prompt = "Use folder"
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
        statusLine = "Starting the runtime."

        do {
            try await persistConfig()
            let _: SimpleOKResponse = try await request(
                path: "/api/container-runtime/start",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            try await refreshState()
            statusLine = "Runtime is starting."
        } catch {
            errorLine = describe(error)
        }

        isBusy = false
    }

    func installAction() async {
        guard !isBusy else { return }
        isBusy = true
        errorLine = nil
        statusLine = "Installing RoachNet."
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
            statusLine = "Installing RoachNet."
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
        statusLine = "Opening RoachNet."

        do {
            try await persistConfig()
            let targetPath =
                config.installedAppPath.isEmpty
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
            let phase = state.activeTask?.phase ?? "Setup running."
            let currentStep = state.activeTask?.currentStep?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let progress = state.activeTask?.progress {
                if let currentStep, !currentStep.isEmpty {
                    statusLine = "\(phase) (\(progress)%) - \(currentStep)"
                } else {
                    statusLine = "\(phase) (\(progress)%)"
                }
            } else {
                if let currentStep, !currentStep.isEmpty {
                    statusLine = "\(phase) - \(currentStep)"
                } else {
                    statusLine = phase
                }
            }
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
        let completedPersistedInstall =
            !startedInstallInCurrentSession
            && stage == .welcome
            && installCompleted
            && state.config.setupCompletedAt != nil
        let canAdvanceToFinishFromCurrentStage = stage.rawValue >= SetupStage.roachClaw.rawValue

        if completedInstallInCurrentSession || completedPersistedInstall,
            allowAutomaticFinishAdvance,
            canAdvanceToFinishFromCurrentStage || completedPersistedInstall
        {
            stage = .finish
            statusLine = "Install complete."

            if config.autoLaunch,
                completedInstallInCurrentSession,
                state.nativeApp.installed
            {
                scheduleAutomaticExitIfNeeded()
            }
        } else if stage == .finish && !installCompleted {
            stage = .roachClaw
            scheduledAutomaticExit = false
        }
    }

    private func stateQueryItems() -> [URLQueryItem] {
        guard
            Self.shouldApplyDraftStateOverrides(
                startedInstallInCurrentSession: startedInstallInCurrentSession,
                activeTaskStatus: setupState?.activeTask?.status
            )
        else {
            return []
        }

        let installPath =
            config.installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath
        let installedAppPath =
            config.installedAppPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: installPath)
            : config.installedAppPath
        let storagePath =
            config.storagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            URLQueryItem(name: "roachClawExtraModels", value: config.roachClawExtraModels.joined(separator: ",")),
            URLQueryItem(name: "companionEnabled", value: config.companionEnabled ? "true" : "false"),
            URLQueryItem(name: "companionHost", value: config.companionHost),
            URLQueryItem(name: "companionPort", value: String(config.companionPort)),
            URLQueryItem(name: "companionToken", value: config.companionToken),
            URLQueryItem(name: "companionAdvertisedURL", value: config.companionAdvertisedURL),
            URLQueryItem(name: "autoLaunch", value: config.autoLaunch ? "true" : "false"),
            URLQueryItem(name: "releaseChannel", value: config.releaseChannel),
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

        let recordedDates = [lastCompletedTask?.startedAt, lastCompletedTask?.finishedAt]
            .compactMap { $0 }
            .compactMap(Self.parseSetupTaskDate)

        guard let newestRecordedDate = recordedDates.max() else {
            return false
        }

        return newestRecordedDate >= installRequestSentAt.addingTimeInterval(-1)
    }

    nonisolated static func parseSetupTaskDate(_ rawValue: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
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

        if let nativeHelper = RoachNetRepositoryLocator.nativeRuntimeBinary() {
            try await startNativeBackend(helperPath: nativeHelper, setupWorkspaceRoot: setupWorkspaceRoot)
            return
        }

        let bundledSourceDirectory = Bundle.main.resourceURL?
            .appendingPathComponent("RoachNetSource", isDirectory: true)
        if let bundledSourceDirectory,
            FileManager.default.fileExists(atPath: bundledSourceDirectory.path)
        {
            statusLine = "Starting the local setup service."
        } else {
            statusLine = "Preparing bundled setup files. First launch can take a minute."
        }

        let repoRoot = await Task.detached(priority: .userInitiated) {
            RoachNetRepositoryLocator.repositoryRoot()
        }.value

        guard let repoRoot else {
            throw NSError(
                domain: "RoachNetSetup", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet Setup couldn't find its setup files. Download RoachNet Setup again, then run it."
                ])
        }

        let scriptURL = repoRoot.appendingPathComponent("scripts/run-roachnet-setup.mjs")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(
                domain: "RoachNetSetup", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "RoachNet Setup couldn't find its setup service at \(scriptURL.path). Download RoachNet Setup again, then run it."
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
            environment["ROACHNET_SETUP_APP_BUNDLE"] =
                installerAssets
                .appendingPathComponent("setup-assets.marker")
                .path
        }
        process.environment = environment

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        attachBackendOutputDrain(stdoutPipe, label: "setup")
        attachBackendOutputDrain(stderrPipe, label: "setup")

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let data = try? Data(contentsOf: readyFileURL),
                let ready = try? JSONDecoder().decode(ReadyFile.self, from: data),
                let url = URL(string: ready.url)
            {
                serverURL = url
                return
            }

            if !process.isRunning {
                throw NSError(
                    domain: "RoachNetSetup", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                            fallback: "The setup service stopped unexpectedly. Quit RoachNet Setup and open it again.",
                            includePipeOutput: true
                        )
                    ])
            }

            try await Task.sleep(for: .milliseconds(250))
        }

        throw NSError(
            domain: "RoachNetSetup", code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                    fallback: "The setup service didn't start in time. Quit RoachNet Setup and open it again.",
                    includePipeOutput: false
                )
            ])
    }

    private func startNativeBackend(helperPath: String, setupWorkspaceRoot: String) async throws {
        statusLine = "Starting the local setup service."
        backendScriptURL = nil

        let readyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roachnet-setup-\(UUID().uuidString).json")
        self.readyFileURL = readyFileURL

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["--setup"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["ROACHNET_SETUP_READY_FILE"] = readyFileURL.path
        environment["ROACHNET_SETUP_WORK_ROOT"] = setupWorkspaceRoot
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            environment["ROACHNET_APP_VERSION"] = version
        }
        if let installerAssets = RoachNetRepositoryLocator.bundledInstallerAssetsDirectory() {
            environment["ROACHNET_SETUP_APP_BUNDLE"] =
                installerAssets
                .appendingPathComponent("setup-assets.marker")
                .path
        }
        process.environment = environment

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        attachBackendOutputDrain(stdoutPipe, label: "setup")
        attachBackendOutputDrain(stderrPipe, label: "setup")

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = try? Data(contentsOf: readyFileURL),
                let ready = try? JSONDecoder().decode(ReadyFile.self, from: data),
                let url = URL(string: ready.url)
            {
                serverURL = url
                return
            }

            if !process.isRunning {
                throw NSError(
                    domain: "RoachNetSetup", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                            fallback:
                                "The setup service stopped before it was ready. Quit RoachNet Setup and open it again.",
                            includePipeOutput: true
                        )
                    ])
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        throw NSError(
            domain: "RoachNetSetup", code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: makeBackendBootFailureMessage(
                    fallback: "The setup service didn't start in time. Quit RoachNet Setup and open it again.",
                    includePipeOutput: false
                )
            ])
    }

    private func terminateBackendProcess() {
        let childPid = process?.processIdentifier

        let nativeInstallRunning = backendScriptURL == nil && setupState?.activeTask?.status == "running"

        if let process, process.isRunning {
            process.terminate()

            if !nativeInstallRunning {
                let deadline = Date().addingTimeInterval(2.5)

                while process.isRunning && Date() < deadline {
                    usleep(100_000)
                }

                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        if let backendScriptURL {
            Self.terminateSetupBackends(scriptURL: backendScriptURL, excluding: childPid)
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
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
        let matchingPids =
            rawOutput
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
            throw NSError(
                domain: "RoachNetSetup", code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "The setup service isn't running. Quit RoachNet Setup and open it again."
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
            throw NSError(
                domain: "RoachNetSetup", code: 408,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Docker didn't answer RoachNet Setup in time. It may still be starting on this Mac. Wait a moment, then try the Runtime step again."
                ])
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500

        if (200..<300).contains(statusCode) {
            return try JSONDecoder().decode(Response.self, from: data)
        }

        if let apiError = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw NSError(
                domain: "RoachNetSetup", code: statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: apiError.error
                ])
        }

        throw NSError(
            domain: "RoachNetSetup", code: statusCode,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The setup service returned an error (HTTP \(statusCode)). Try the step again."
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
            return "RoachNet Setup couldn't read a reply from the setup service. Refresh and try the step again."
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("couldn’t be read because it isn’t in the correct format")
            || description.localizedCaseInsensitiveContains("isn’t in the correct format")
        {
            return "RoachNet Setup couldn't read a reply from the setup service. Refresh and try the step again."
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
            return
                "There isn't enough free disk space for this install. Free up space, choose an install root on a drive with more room, or turn off Install RoachClaw and set up RoachClaw once RoachNet opens."
        }

        if description.localizedCaseInsensitiveContains("reading 'includes'")
            || description.localizedCaseInsensitiveContains("reading \\\"includes\\\"")
        {
            return
                "A check of RoachNet Setup's bundled tools failed. Download a fresh copy of RoachNet Setup and run the install again."
        }

        if description.localizedCaseInsensitiveContains("npm error")
            || description.localizedCaseInsensitiveContains("npm install")
        {
            return
                "RoachNet Setup couldn't finish installing one of its bundled tools. Try the install again. If it fails again, turn off Install RoachClaw, install the app and set up RoachClaw after RoachNet opens."
        }

        if description.localizedCaseInsensitiveContains("timed out")
            && description.localizedCaseInsensitiveContains("runtime")
        {
            return
                "The runtime didn't answer RoachNet Setup in time. It can take longer on a first start. Try the install again."
        }

        return description
    }

    private func makeBackendBootFailureMessage(fallback: String, includePipeOutput: Bool) -> String {
        if let summary = backendOutputSummary() {
            return "\(fallback)\n\nRecent output from the setup service:\n\(summary)"
        }

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

    private func attachBackendOutputDrain(_ pipe: Pipe, label: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.recordBackendOutput(label: label, text: text)
            }
        }
    }

    private func recordBackendOutput(label: String, text: String) {
        let lines =
            text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        backendOutputTail.append(contentsOf: lines.map { "[\(label)] \($0)" })
        if backendOutputTail.count > 16 {
            backendOutputTail.removeFirst(backendOutputTail.count - 16)
        }
    }

    private func backendOutputSummary() -> String? {
        guard !backendOutputTail.isEmpty else { return nil }
        return backendOutputTail.joined(separator: "\n")
    }

    private static func readPipeOutput(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func preferredSetupWorkspaceRoot() -> String {
        if let override = ProcessInfo.processInfo.environment["ROACHNET_SETUP_WORK_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }

        let candidateInstallPath =
            config.installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RoachNetRepositoryLocator.defaultInstallPath()
            : config.installPath

        var candidates: [URL] = [
            URL(fileURLWithPath: RoachNetRepositoryLocator.defaultSetupWorkspaceRoot(installPath: candidateInstallPath))
        ]

        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .isWritableKey, .volumeIsReadOnlyKey,
            ],
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
            ?? URL(
                fileURLWithPath: RoachNetRepositoryLocator.defaultSetupWorkspaceRoot(installPath: candidateInstallPath)
            ).standardizedFileURL.path
    }

    private func availableCapacity(for workspaceURL: URL) -> Int64 {
        let probeURL = workspaceURL.deletingLastPathComponent()
        do {
            let values = try probeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .isWritableKey, .volumeIsReadOnlyKey,
            ])
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
        .defaultSize(width: 980, height: 740)
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
        SetupSnapshotHook.shared.armIfRequested(controller: controller)
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
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = proxy.size.width < 920 ? 14.0 : 20.0
            let verticalPadding = proxy.size.height < 720 ? 18.0 : 30.0

            ZStack {
                RoachBackground()

                VStack(spacing: 18) {
                    chromeBar(width: proxy.size.width - (horizontalPadding * 2))
                    mainCard
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 18)
                        .scaleEffect(appeared ? 1 : 0.985, anchor: .top)
                }
                .frame(maxWidth: 1120, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, verticalPadding)
                .padding(.bottom, 18)
            }
        }
        .tint(RoachPalette.action)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: controller.stage)
        .animation(.spring(response: 0.54, dampingFraction: 0.86), value: appeared)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.spring(response: 0.54, dampingFraction: 0.86)) {
                appeared = true
            }
        }
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
            GeometryReader { proxy in
                let useSplitInstaller = proxy.size.width >= 900 && proxy.size.height >= 500

                if useSplitInstaller {
                    HStack(spacing: 0) {
                        setupProgressRail
                            .frame(width: 258, alignment: .topLeading)
                            .padding(.trailing, 16)

                        Rectangle()
                            .fill(RoachPalette.border.opacity(0.72))
                            .frame(width: 1)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)

                        setupContentDeck(showsStageStrip: false)
                            .padding(.leading, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    setupContentDeck(showsStageStrip: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func setupContentDeck(showsStageStrip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if showsStageStrip {
                        progressHeader
                    }
                    setupSignalStrip
                    stageHero
                        .id("stage-hero-\(controller.stage.rawValue)")
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity).combined(
                                    with: .scale(scale: 0.98, anchor: .topLeading)),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(
                                    with: .scale(scale: 0.99, anchor: .topLeading))
                            )
                        )
                    stageContent
                        .id("stage-content-\(controller.stage.rawValue)")
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity).combined(
                                    with: .scale(scale: 0.985, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.99, anchor: .top))
                            )
                        )

                    if showStatusSection {
                        statusSection
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(RoachPalette.border.opacity(0.72))
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .allowsHitTesting(false)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var setupProgressRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                RoachLED(
                    controller.isBooting ? RoachPalette.warning : RoachPalette.signal, size: 7,
                    pulses: controller.isBooting)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup service")
                        .font(.roach(size: 13, weight: .semibold))
                        .foregroundStyle(RoachPalette.text)
                    Text(controller.isBooting ? "Starting" : "Ready")
                        .font(.roach(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(RoachPalette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roachSurface(.sunken, radius: 12)
            .accessibilityElement(children: .combine)

            RoachInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    RoachKicker("Install path")
                    Text(installRootLabel(controller.config.installPath))
                        .font(.roach(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(RoachPalette.text)
                        .lineLimit(2)
                    Text(
                        contentFolderLabel(
                            controller.config.storagePath.isEmpty
                                ? RoachNetRepositoryLocator.defaultStoragePath(
                                    installPath: controller.config.installPath)
                                : controller.config.storagePath
                        )
                    )
                    .font(.roach(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                RoachKicker("Steps")
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                ForEach(SetupStage.allCases) { stage in
                    setupRailStep(stage)
                }
            }
            .padding(.leading, 6)

            if let progress = controller.setupState?.activeTask?.progress {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            RoachKicker("Current task")
                            Spacer()
                            Text("\(progress)%")
                                .font(.roach(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(RoachPalette.green)
                        }
                        GeometryReader { proxy in
                            Capsule(style: .continuous)
                                .fill(RoachPalette.border.opacity(0.74))
                                .overlay(alignment: .leading) {
                                    Capsule(style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [RoachPalette.green, RoachPalette.magenta],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(10, proxy.size.width * CGFloat(progress) / 100))
                                }
                        }
                        .frame(height: 7)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func setupRailStep(_ stage: SetupStage) -> some View {
        let isActive = stage == controller.stage
        let isComplete = stage.rawValue < controller.stage.rawValue
        let isLit = isActive || isComplete
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(10), style: .continuous)
        let badgeShape = RoundedRectangle(cornerRadius: RoachMetrics.radius(6), style: .continuous)
        let state = isComplete ? "Done" : (isActive ? "Now" : "To do")

        return HStack(spacing: 10) {
            Group {
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.roach(size: 9, weight: .bold))
                } else {
                    Text(String(format: "%02d", stage.rawValue + 1))
                        .font(.roach(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                }
            }
            .foregroundStyle(isLit ? RoachPalette.signal : RoachPalette.muted)
            .frame(width: 36, height: 22)
            .background(badgeShape.fill(RoachPalette.backgroundRaised))
            .overlay(
                badgeShape.strokeBorder(
                    isActive ? RoachPalette.signal.opacity(0.55) : RoachPalette.border, lineWidth: RoachMetrics.line(1))
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(.roach(size: 13.5, weight: .medium))
                    .foregroundStyle(isActive ? RoachPalette.text : RoachPalette.text.opacity(0.8))
                    .lineLimit(1)
                Text(state)
                    .font(.roach(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isLit ? RoachPalette.signal : RoachPalette.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background {
            if isActive {
                ZStack {
                    shape.fill(RoachPalette.panelRaised)
                    shape.fill(RoachPalette.accent.opacity(0.14))
                }
            }
        }
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(RoachPalette.signal)
                .frame(width: 3)
                .padding(.vertical, 10)
                .shadow(color: RoachPalette.signal.opacity(RoachMetrics.glow(0.8)), radius: 4)
                .opacity(isActive ? 1 : 0)
                .offset(x: -6)
        }
        .roachAnimation(.medium, .assemble, value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Step \(stage.rawValue + 1) of \(SetupStage.allCases.count): \(stage.title), \(state.lowercased())")
    }

    private var setupTitleLockup: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                RoachOrbitMark()
                    .frame(width: 64, height: 64)
                setupTitleText(size: 26)
            }

            VStack(alignment: .leading, spacing: 10) {
                RoachOrbitMark()
                    .frame(width: 56, height: 56)
                setupTitleText(size: 22)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func setupTitleText(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RoachNet Setup")
                .font(.roach(size: size, weight: .heavy, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(RoachPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            RoachKicker("Offline on purpose", led: true)
            Text("Installs RoachNet in its own folder.")
                .font(.roach(size: 12, weight: .regular))
                .foregroundStyle(RoachPalette.muted)
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RoachKicker("Setup steps")

                Spacer()

                Text("\(controller.stage.rawValue + 1) / \(SetupStage.allCases.count)")
                    .font(.roach(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                RoachStageStrip(titles: controller.stageTitles, activeIndex: controller.stage.rawValue)
            }
        }
    }

    private var setupSignalStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                setupSignalChip(
                    "Root", value: installRootLabel(controller.config.installPath), accent: RoachPalette.green)
                setupSignalChip("Runtime", value: runtimeModeValue, accent: RoachPalette.magenta)
                setupSignalChip("AI", value: setupModelChoiceLabel, accent: RoachPalette.cyan)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 10)], alignment: .leading, spacing: 10) {
                setupSignalChip(
                    "Root", value: installRootLabel(controller.config.installPath), accent: RoachPalette.green)
                setupSignalChip("Runtime", value: runtimeModeValue, accent: RoachPalette.magenta)
                setupSignalChip("AI", value: setupModelChoiceLabel, accent: RoachPalette.cyan)
            }
        }
    }

    private func setupSignalChip(_ title: String, value: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .shadow(color: accent.opacity(0.55), radius: 8, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.roach(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(accent)
                Text(value)
                    .font(.roach(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                .fill(RoachPalette.panel.opacity(0.50))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }

    private var stageHero: some View {
        HStack(alignment: .top, spacing: 18) {
            stageHeroCopy
                .frame(maxWidth: .infinity, alignment: .leading)

            stageHeroGlyph
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
                        detail:
                            "Setup checks free space and any earlier install, then adds only the parts of RoachNet that are missing.",
                        systemName: "desktopcomputer",
                        accent: RoachPalette.green
                    )
                    RoachFeatureTile(
                        "Runtime",
                        title: "Set up the runtime",
                        detail:
                            "RoachNet brings its own local services, so you don't need anything else installed first.",
                        systemName: "server.rack",
                        accent: RoachPalette.magenta
                    )
                    RoachFeatureTile(
                        "Launch",
                        title: "Open RoachNet",
                        detail: "Start using the app once storage, the runtime and your first model are ready.",
                        systemName: "sparkles",
                        accent: RoachPalette.cyan
                    )
                }
            }

        case .machine:
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Install folder", value: installRootLabel(controller.config.installPath))
                    RoachInfoPill(title: "App location", value: appTargetLabel(controller.config.installedAppPath))
                    RoachInfoPill(
                        title: "Content folder",
                        value: contentFolderLabel(
                            controller.config.storagePath.isEmpty
                                ? RoachNetRepositoryLocator.defaultStoragePath(
                                    installPath: controller.config.installPath)
                                : controller.config.storagePath
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { setupFolderButtons }
                        VStack(alignment: .leading, spacing: 10) { setupFolderButtons }
                    }

                    Text("You can change this later from Runtime.")
                        .font(.roach(size: 12, weight: .medium))
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
                    RoachInfoPill(title: "Runtime mode", value: runtimeModeValue)
                    RoachInfoPill(title: "Container runtime", value: runtimeValue)
                    RoachInfoPill(title: "Services", value: servicesValue)
                    RoachInfoPill(
                        title: "Storage",
                        value: contentFolderLabel(
                            controller.config.storagePath.isEmpty
                                ? RoachNetRepositoryLocator.defaultStoragePath(
                                    installPath: controller.config.installPath)
                                : controller.config.storagePath
                        )
                    )
                }

                RoachInsetPanel {
                    setupToggleRow(
                        "Use Docker containerization",
                        detail:
                            "Leave this off and RoachNet runs its services from its own folder. Turn it on only if you want support services in Docker; RoachNet Setup doesn't install Docker.",
                        isOn: $controller.config.useDockerContainerization
                    )
                }

                RoachInsetPanel {
                    setupToggleRow(
                        "Enable RoachTail pairing",
                        detail:
                            "Turn this on if you want RoachNet for iOS on your iPhone or iPad to pair with this Mac using a one-time join code.",
                        isOn: $controller.config.companionEnabled
                    )
                }

                if controller.config.useDockerContainerization {
                    SetupNativeButton(title: "Start runtime now", role: .secondary, isEnabled: !controller.isBusy) {
                        Task { await controller.startRuntimeAction() }
                    }
                }
            }

        case .roachClaw:
            VStack(alignment: .leading, spacing: 16) {
                RoachInsetPanel {
                    setupToggleRow(
                        "Set up RoachClaw",
                        detail:
                            "Turn this off to skip local AI for now. Models are checked before use and run on this Mac.",
                        isOn: $controller.config.installRoachClaw
                    )
                }

                setupModelPicker
                    .disabled(!controller.config.installRoachClaw)
                    .opacity(controller.config.installRoachClaw ? 1 : 0.5)
            }

        case .finish:
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        RoachTag("RoachNet ready")
                        if controller.config.installRoachClaw {
                            RoachTag(setupModelChoiceLabel, accent: RoachPalette.magenta)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        RoachTag("RoachNet ready")
                        if controller.config.installRoachClaw {
                            RoachTag(setupModelChoiceLabel, accent: RoachPalette.magenta)
                        }
                    }
                }

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(
                        title: "Main app",
                        value: controller.setupState?.nativeApp.installed == true ? "Installed" : "Ready")
                    RoachInfoPill(
                        title: "RoachClaw", value: controller.config.installRoachClaw ? setupModelCountLabel : "Skipped"
                    )
                    RoachInfoPill(title: "Runtime", value: servicesValue)
                    RoachInfoPill(title: "RoachTail", value: controller.config.companionEnabled ? "On" : "Off")
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
                RoachNotice(
                    title: "Starting setup", detail: controller.statusLine, accent: RoachPalette.green,
                    systemName: "arrow.triangle.2.circlepath")
            } else {
                RoachNotice(
                    title: "Installer status", detail: controller.statusLine, accent: RoachPalette.green,
                    systemName: "checkmark.circle.fill")
            }

            if let logs = controller.setupState?.activeTask?.logs, !logs.isEmpty {
                RoachInsetPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        RoachKicker("Recent setup log")
                        ForEach(Array(logs.suffix(2).enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.roach(size: 12, weight: .medium, design: .monospaced))
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
            footerStatus
            footerButtons
                .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .fill(RoachPalette.backgroundRaised.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RoachMetrics.radius(18), style: .continuous)
                .stroke(RoachPalette.border.opacity(0.82), lineWidth: 1)
        )
    }

    private var footerStatus: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(footerAccent.opacity(0.16))
                Image(systemName: footerIcon)
                    .font(.roach(size: 11, weight: .bold))
                    .foregroundStyle(footerAccent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(footerTitle)
                    .font(.roach(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(RoachPalette.text)
                    .lineLimit(1)
                Text(footerDetail)
                    .font(.roach(size: 11, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            SetupNativeButton(title: "Back", role: .secondary, isEnabled: controller.canGoBack, minWidth: 84) {
                controller.back()
            }

            SetupNativeButton(
                title: primaryTitle,
                role: .primary,
                isEnabled: !(controller.isBooting || controller.isBusy || controller.primaryActionCoolingDown),
                isDefaultAction: true,
                minWidth: 128
            ) {
                guard controller.beginPrimaryAction() else { return }
                Task { await controller.primaryAction() }
            }
            .id("primary-\(controller.stage.rawValue)")
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
        }
    }

    private var footerIcon: String {
        if controller.errorLine != nil {
            return "exclamationmark.triangle.fill"
        }
        if controller.isBooting || controller.isBusy {
            return "arrow.triangle.2.circlepath"
        }
        return controller.stage == .finish ? "checkmark.circle.fill" : "arrow.right.circle.fill"
    }

    private var footerAccent: Color {
        if controller.errorLine != nil {
            return RoachPalette.warning
        }
        if controller.isBooting || controller.isBusy {
            return RoachPalette.cyan
        }
        return controller.stage == .finish ? RoachPalette.green : stageAccent
    }

    private var footerTitle: String {
        if controller.errorLine != nil {
            return "Installer needs attention"
        }
        if controller.isBooting {
            return "Starting local setup"
        }
        if controller.isBusy {
            return "Working on it"
        }
        return controller.stage == .finish ? "Ready to launch" : "Next step is ready"
    }

    private var footerDetail: String {
        if controller.errorLine != nil {
            return "Nothing else was touched."
        }
        if controller.isBooting || controller.isBusy {
            return controller.statusLine
        }
        return "No account needed. Setup leaves your other files alone."
    }

    private func welcomeCard(title: String, detail: String) -> some View {
        RoachInsetPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.roach(size: 17, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 13, weight: .regular))
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
            return controller.isBusy ? "Installing…" : "Install RoachNet"
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
                ("Container runtime", runtimeValue, RoachPalette.green),
                (
                    "Services", servicesValue,
                    controller.setupState?.installLooksReady == true ? RoachPalette.green : RoachPalette.warning
                ),
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
                accent =
                    dependency.available
                    ? RoachPalette.success : (dependency.required ? RoachPalette.warning : RoachPalette.muted)
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
        return "Needs setup"
    }

    private var runtimeModeValue: String {
        controller.config.useDockerContainerization ? "Docker" : "Built-in"
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

    @ViewBuilder
    private var setupFolderButtons: some View {
        SetupNativeButton(title: "Choose install folder…", role: .secondary) {
            controller.chooseInstallFolder()
        }
        SetupNativeButton(title: "Choose content folder…", role: .secondary) {
            controller.chooseStorageFolder()
        }
    }

    private func setupToggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityHint(detail)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.roach(size: 15, weight: .semibold))
                    .foregroundStyle(RoachPalette.text)
                Text(detail)
                    .font(.roach(size: 13, weight: .regular))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
    }

    private var stageHeroCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoachKicker(controller.stage.title)
            RoachDisplayTitle(controller.stage.headline, size: 30)
                .minimumScaleFactor(0.80)
            Text(controller.stage.detail)
                .font(.roach(size: 13, weight: .medium))
                .foregroundStyle(RoachPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stageHeroGlyph: some View {
        if controller.stage == .welcome || controller.stage == .finish {
            RoachOrbitMark()
                .frame(width: 86, height: 86)
        } else {
            Image(systemName: stageSystemImage)
                .font(.roach(size: 28, weight: .semibold))
                .foregroundStyle(stageAccent)
                .frame(width: 78, height: 78)
                .background(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(22), style: .continuous)
                        .fill(stageAccent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RoachMetrics.radius(22), style: .continuous)
                        .stroke(stageAccent.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private func stageIcon(for stage: SetupStage) -> String {
        switch stage {
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

    private var stageSystemImage: String {
        stageIcon(for: controller.stage)
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

@MainActor
final class SetupSnapshotHook {
    static let shared = SetupSnapshotHook()

    private var source: DispatchSourceSignal?
    private weak var controller: SetupController?

    func armIfRequested(controller: SetupController?) {
        guard source == nil,
            let directory = ProcessInfo.processInfo.environment["ROACHNET_UI_SNAPSHOT_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty
        else { return }
        self.controller = controller
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.snapshot(into: URL(fileURLWithPath: directory, isDirectory: true))
            }
        }
        source.resume()
        self.source = source
    }

    private func snapshot(into directory: URL) {
        if let name = (try? String(contentsOf: directory.appendingPathComponent("stage.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let stage = SetupStage.allCases.first(where: { String(describing: $0) == name }),
            controller?.stage != stage
        {
            controller?.stage = stage
        }
        if let errorLine = controller?.errorLine {
            NSLog("[RoachNet Setup snapshot] Setup reports: \(errorLine)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.capture(into: directory)
            }
        }
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private func capture(into directory: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
            let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else {
            NSLog("[RoachNet Setup snapshot] No visible window to capture.")
            return
        }
        let create = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        guard
            let image = create(
                .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber), options)?
                .takeRetainedValue(),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            NSLog("[RoachNet Setup snapshot] The window couldn't be captured.")
            return
        }
        let url = directory.appendingPathComponent("roachnet-setup-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try data.write(to: url, options: .atomic)
            NSLog("[RoachNet Setup snapshot] Wrote \(url.path)")
        } catch {
            NSLog("[RoachNet Setup snapshot] Couldn't write \(url.path): \(error.localizedDescription)")
        }
    }
}

extension SetupRootView {
    fileprivate var setupLibraryModels: [RoachModelLibraryEntry] {
        RoachModelLibraryEntry.displayOrder((controller.setupState?.models ?? []).filter(\.fitsThisMac))
    }

    fileprivate var setupTooBigCount: Int {
        (controller.setupState?.models ?? []).filter { !$0.fitsThisMac }.count
    }

    var setupChosenModels: [RoachModelLibraryEntry] {
        let library = controller.setupState?.models ?? []
        let names = [controller.config.roachClawDefaultModel] + controller.config.roachClawExtraModels
        return names.compactMap { name in library.first { $0.name == name } }
    }

    fileprivate var setupDownloadSummary: String {
        let chosen = setupChosenModels
        guard !chosen.isEmpty else { return "" }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        let count = chosen.count == 1 ? "1 model" : "\(chosen.count) models"
        return "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) to download"
    }

    var setupModelCountLabel: String {
        let count = 1 + controller.config.roachClawExtraModels.count
        return count == 1 ? "1 model" : "\(count) models"
    }

    var setupModelChoiceLabel: String {
        guard controller.config.installRoachClaw else { return "Skipped" }
        let first =
            setupChosenModels.first { $0.name == controller.config.roachClawDefaultModel }?.title
            ?? controller.config.roachClawDefaultModel
        let extras = controller.config.roachClawExtraModels.count
        return extras > 0 ? "\(first) +\(extras)" : first
    }

    @ViewBuilder
    var setupModelPicker: some View {
        let models = setupLibraryModels
        if models.isEmpty {
            RoachInlineField(
                title: "First model", value: $controller.config.roachClawDefaultModel, placeholder: "qwen2.5-coder:1.5b"
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RoachKicker("Models for this Mac")
                    Spacer(minLength: 8)
                    Text(setupDownloadSummary)
                        .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RoachPalette.signal)
                        .lineLimit(1)
                }

                ForEach(models) { entry in
                    setupModelRow(entry)
                }

                if setupTooBigCount > 0 {
                    Text(
                        "\(setupTooBigCount == 1 ? "1 more needs" : "\(setupTooBigCount) more need") more memory than this Mac has. Settings › Models lists every model."
                    )
                    .font(.roach(size: 12, weight: .medium))
                    .foregroundStyle(RoachPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setupModelRow(_ entry: RoachModelLibraryEntry) -> some View {
        let isFirst = controller.config.roachClawDefaultModel == entry.name
        let isExtra = controller.config.roachClawExtraModels.contains(entry.name)
        let shape = RoundedRectangle(cornerRadius: RoachMetrics.radius(14), style: .continuous)

        return HStack(alignment: .center, spacing: 12) {
            Button {
                controller.config.roachClawDefaultModel = entry.name
                controller.config.roachClawExtraModels.removeAll { $0 == entry.name }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isFirst ? RoachPalette.signal : RoachPalette.borderStrong,
                                lineWidth: RoachMetrics.line(1.5))
                        if isFirst {
                            Circle()
                                .fill(RoachPalette.signal)
                                .padding(4)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(entry.title)
                                .font(.roach(size: 14, weight: .semibold))
                                .foregroundStyle(RoachPalette.text)
                                .lineLimit(1)
                            if entry.recommended {
                                RoachTag("Best fit", accent: RoachPalette.accent)
                            }
                        }
                        Text(entry.specLine)
                            .font(.roach(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RoachPalette.muted)
                            .lineLimit(1)
                        HStack(alignment: .center, spacing: 7) {
                            RoachLED(entry.fit == "good" ? RoachPalette.signal : RoachPalette.warning, size: 6)
                            Text("\(entry.fitLabel) · \(entry.makerLine)")
                                .font(.roach(size: 11.5, weight: .medium))
                                .foregroundStyle(RoachPalette.text.opacity(0.82))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start with \(entry.title)")
            .accessibilityValue("\(entry.specLine). \(entry.fitLabel).")
            .accessibilityAddTraits(isFirst ? .isSelected : [])

            if isFirst {
                Text("Starts with this")
                    .font(.roach(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RoachPalette.signal)
                    .fixedSize()
            } else {
                Toggle(
                    "Also download",
                    isOn: Binding(
                        get: { isExtra },
                        set: { wanted in
                            if wanted {
                                if !controller.config.roachClawExtraModels.contains(entry.name) {
                                    controller.config.roachClawExtraModels.append(entry.name)
                                }
                            } else {
                                controller.config.roachClawExtraModels.removeAll { $0 == entry.name }
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.roach(size: 12, weight: .medium))
                .fixedSize()
                .accessibilityLabel("Also download \(entry.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(shape.fill(isFirst ? RoachPalette.accent.opacity(0.12) : RoachPalette.panel.opacity(0.42)))
        .overlay(
            shape.strokeBorder(
                isFirst ? RoachPalette.signal.opacity(0.5) : RoachPalette.border.opacity(0.82),
                lineWidth: RoachMetrics.line(1))
        )
        .roachAnimation(.short, .assemble, value: isFirst)
    }
}
