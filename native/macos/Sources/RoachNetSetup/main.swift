import Foundation
import SwiftUI
import AppKit
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
        case .welcome: return "Get RoachNet ready."
        case .machine: return "Check this Mac."
        case .runtime: return "Prepare the local runtime."
        case .roachClaw: return "Set up local AI."
        case .finish: return "Open RoachNet."
        }
    }

    var detail: String {
        switch self {
        case .welcome: return "RoachNet handles setup first, so the app can open clean."
        case .machine: return "We’ll see what’s already installed and what still needs a hand."
        case .runtime: return "RoachNet keeps the local services contained and close to the app."
        case .roachClaw: return "Ollama and OpenClaw start from one sane local default."
        case .finish: return "You’re ready to move into the command deck."
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

    private var allowAutomaticFinishAdvance = true
    private var process: Process?
    private var readyFileURL: URL?
    private var serverURL: URL?
    private var pollTask: Task<Void, Never>?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var stageTitles: [String] { SetupStage.allCases.map(\.title) }
    var canGoBack: Bool { stage != .welcome && !isBusy }

    init() {
        Task {
            await boot()
        }
    }

    deinit {
        pollTask?.cancel()
        process?.terminate()

        if let readyFileURL {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
    }

    func shutdown() {
        pollTask?.cancel()
        process?.terminate()

        if let readyFileURL {
            try? FileManager.default.removeItem(at: readyFileURL)
        }
    }

    func boot() async {
        isBooting = true
        errorLine = nil
        statusLine = "Booting setup."

        do {
            try await ensureBackend()
            try await refreshState()
            startPolling()
            statusLine = "Setup ready."
        } catch {
            errorLine = describe(error)
            statusLine = "Setup backend unavailable."
        }

        isBooting = false
    }

    func back() {
        guard let previous = SetupStage(rawValue: stage.rawValue - 1) else { return }
        allowAutomaticFinishAdvance = false
        stage = previous
    }

    func primaryAction() async {
        allowAutomaticFinishAdvance = true
        switch stage {
        case .welcome:
            stage = .machine
        case .machine:
            await refreshAction()
            stage = .runtime
        case .runtime:
            stage = .roachClaw
        case .roachClaw:
            await installAction()
        case .finish:
            await launchAction()
        }
    }

    func refreshAction() async {
        do {
            try await persistConfig()
            try await refreshState()
            statusLine = "State refreshed."
        } catch {
            errorLine = describe(error)
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

    func startRuntimeAction() async {
        guard !isBusy else { return }
        isBusy = true
        errorLine = nil
        statusLine = "Starting container runtime."

        do {
            try await persistConfig()
            let _: SimpleOKResponse = try await request(
                path: "/api/container-runtime/start",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            try await refreshState()
            statusLine = "Runtime start requested."
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

        do {
            try await persistConfig()
            let _: SimpleOKResponse = try await request(
                path: "/api/install",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            startPolling()
            statusLine = "Install running."
        } catch {
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
            let _: SimpleOKResponse = try await request(
                path: "/api/launch",
                method: "POST",
                body: config,
                as: SimpleOKResponse.self
            )
            statusLine = "RoachNet launched."
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
        let state = try await request(path: "/api/state", method: "GET", as: RoachNetSetupState.self)
        setupState = state
        config = state.config

        if state.activeTask?.status == "running" {
            statusLine = state.activeTask?.phase ?? "Setup running."
            isBusy = true
        } else {
            isBusy = false
        }

        let installCompleted =
            state.lastCompletedTask?.status == "completed"
            || state.nativeApp.installed
            || state.config.setupCompletedAt != nil

        if installCompleted, allowAutomaticFinishAdvance {
            stage = .finish
            if state.lastCompletedTask?.status == "completed" {
                statusLine = "Install complete."
            }
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

        guard let repoRoot = RoachNetRepositoryLocator.repositoryRoot() else {
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

        let readyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roachnet-setup-\(UUID().uuidString).json")
        self.readyFileURL = readyFileURL

        let node = RoachNetRepositoryLocator.preferredNodeBinary()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$ROACHNET_NODE_BINARY\" \"$ROACHNET_SCRIPT_PATH\""]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["ROACHNET_NODE_BINARY"] = node == "/usr/bin/env" ? "node" : node
        environment["ROACHNET_SETUP_NO_BROWSER"] = "1"
        environment["ROACHNET_SETUP_READY_FILE"] = readyFileURL.path
        environment["ROACHNET_REPO_ROOT"] = repoRoot.path
        environment["ROACHNET_SCRIPT_PATH"] = scriptURL.path
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

        let deadline = Date().addingTimeInterval(45)
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
                fallback: "The native installer could not boot the setup backend before the local timeout.",
                includePipeOutput: false
            )
        ])
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await performRequest(path: path, method: method, body: Optional<AnyEncodable>.none, as: type)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        body: some Encodable,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await performRequest(path: path, method: method, body: AnyEncodable(body), as: type)
    }

    private func performRequest<Response: Decodable>(
        path: String,
        method: String,
        body: AnyEncodable?,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        guard let base = serverURL else {
            throw NSError(domain: "RoachNetSetup", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The setup backend is not running."
            ])
        }

        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 120

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
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
    @StateObject private var controller = SetupController()

    var body: some Scene {
        WindowGroup("RoachNet Setup") {
            SetupRootView(controller: controller)
                .frame(minWidth: 760, idealWidth: 980, minHeight: 580, idealHeight: 740)
                .onAppear {
                    appDelegate.controller = controller
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class RoachNetSetupAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: SetupController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shutdown()
        return .terminateNow
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    progressHeader
                    stageHero
                    stageContent

                    if showStatusSection {
                        statusSection
                    }

                    footer
                }
            }
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
                    Text("A calmer way to get set up")
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
                    Text("A calmer way to get set up")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(RoachPalette.muted)
                }
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Install Flow")
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

                if controller.stage == .welcome || controller.stage == .finish {
                    RoachOrbitMark()
                        .frame(width: 108, height: 108)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                stageHeroCopy

                if controller.stage == .welcome || controller.stage == .finish {
                    RoachOrbitMark()
                        .frame(width: 92, height: 92)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch controller.stage {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    welcomeCard(title: "Check this Mac", detail: "See what’s already here and what still needs a hand.")
                    welcomeCard(title: "Stage the runtime", detail: "Prepare the local stack without a pile of manual steps.")
                    welcomeCard(title: "Open RoachNet", detail: "Move straight into the app when everything is ready.")
                }
            }

        case .machine:
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Install Root", value: controller.config.installPath)
                    RoachInfoPill(title: "App Target", value: controller.config.installedAppPath)
                    RoachInfoPill(
                        title: "Content Folder",
                        value: controller.config.storagePath.isEmpty
                            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: controller.config.installPath)
                            : controller.config.storagePath
                    )
                }

                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    ForEach(machineRows, id: \.title) { row in
                        RoachInsetPanel {
                            RoachStatusRow(title: row.title, value: row.value, accent: row.accent)
                        }
                    }
                }

                responsiveBar {
                    EmptyView()
                } actions: {
                    Button("Choose Content Folder") {
                        controller.chooseStorageFolder()
                    }
                    .buttonStyle(RoachSecondaryButtonStyle())

                    Text("You can change this later from RoachNet Runtime too.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RoachPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .runtime:
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                    RoachInfoPill(title: "Container Runtime", value: runtimeValue)
                    RoachInfoPill(title: "Services", value: servicesValue)
                    RoachInfoPill(
                        title: "Storage",
                        value: controller.config.storagePath.isEmpty
                            ? RoachNetRepositoryLocator.defaultStoragePath(installPath: controller.config.installPath)
                            : controller.config.storagePath
                    )
                }

                Button("Start Runtime Now") {
                    Task { await controller.startRuntimeAction() }
                }
                .buttonStyle(RoachSecondaryButtonStyle())
                .disabled(controller.isBusy)
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
                            Text("Keep Ollama and OpenClaw aligned from the first launch.")
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
                        RoachKicker("Recent")
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
        responsiveBar {
            Button("Back") {
                controller.back()
            }
            .buttonStyle(RoachSecondaryButtonStyle())
            .disabled(!controller.canGoBack)
        } actions: {
            Button(primaryTitle) {
                Task { await controller.primaryAction() }
            }
            .buttonStyle(RoachPrimaryButtonStyle())
            .disabled(controller.isBooting || controller.isBusy)
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
            let status = dependency.available ? "Ready" : (dependency.required ? "Needed" : "Optional")
            let accent = dependency.available ? RoachPalette.success : (dependency.required ? RoachPalette.warning : RoachPalette.muted)
            return (dependency.label, status, accent)
        }
    }

    private var runtimeValue: String {
        if controller.setupState?.containerRuntime.ready == true {
            return "Ready"
        }
        if controller.setupState?.containerRuntime.available == true {
            return "Detected"
        }
        return "Needs Setup"
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

    private var summaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 176), spacing: 12, alignment: .top)]
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

    private func responsiveBar<HeaderContent: View, ActionsContent: View>(
        @ViewBuilder header: () -> HeaderContent,
        @ViewBuilder actions: () -> ActionsContent
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                header()
                Spacer(minLength: 12)
                HStack(spacing: 12) {
                    actions()
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                header()
                HStack(spacing: 12) {
                    actions()
                }
            }
        }
    }
}
