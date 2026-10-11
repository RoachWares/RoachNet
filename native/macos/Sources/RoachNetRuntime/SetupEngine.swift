import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native RoachNet installer engine behind RoachNet Setup.
///
/// Serves the setup contract (`/api/state`, `/api/config`, `/api/install`,
/// `/api/launch`, `/api/container-runtime/start`) and installs RoachNet into a
/// self-contained root (`~/RoachNet` by default) with a staged, rollback-safe
/// swap that preserves user storage. No Node, Docker, or package manager.
public final class SetupEngine {
    public static let minimumMacOSMajor = 14
    static let gib: Int64 = 1024 * 1024 * 1024
    static let minimumFreeBase: Int64 = 2 * gib
    static let minimumFreeWithRoachClaw: Int64 = 5 * gib
    static let defaultModel = "qwen2.5-coder:1.5b"
    static let taskLogLimit = 800
    static let installManifestName = "roachnet-install.json"

    let environment: [String: String]
    /// Mirrors task log lines (used by the headless `--install` CLI).
    public var onLog: ((String) -> Void)?
    let version: String
    private let lock = NSRecursiveLock()
    private var activeTask: JSON?
    private var lastCompletedTask: JSON?
    private var persistedConfigCache: JSON?
    var appHelperName: String { RuntimeBuildInfo.executableName }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, version: String = RuntimeConfiguration.shared.version) {
        self.environment = environment
        self.version = version
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Paths

    var home: String { environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? Host.homeDirectory }

    func normalizeInputPath(_ value: JSON) -> String {
        let raw = (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return defaultInstallPath() }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return Path.join(home, String(raw.dropFirst(2))) }
        return Path.resolve(raw)
    }

    func defaultInstallPath() -> String { Path.join(home, "RoachNet") }
    func canonicalAppPath(_ installPath: String) -> String { Path.join(installPath, "app", "RoachNet.app") }

    var sharedAppDataDirectory: String {
        if let explicit = environment["ROACHNET_SHARED_APP_DATA_DIR"], !explicit.isEmpty { return Path.resolve(explicit) }
        return SetupPlatform.isMacOS
            ? Path.join(home, "Library", "Application Support", "roachnet")
            : Path.join(environment["XDG_CONFIG_HOME"] ?? Path.join(home, ".config"), "roachnet")
    }

    var configPath: String {
        if let explicit = environment["ROACHNET_INSTALLER_CONFIG_PATH"], !explicit.isEmpty { return explicit }
        return Path.join(sharedAppDataDirectory, "roachnet-installer.json")
    }

    var legacyConfigPath: String { Path.join(home, ".roachnet-setup.json") }

    /// `Contents/Resources/InstallerAssets` of the running Setup bundle.
    var installerAssetsPath: String? {
        if let explicit = environment["ROACHNET_SETUP_APP_BUNDLE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let normalized = Path.resolve(explicit)
            if Path.basename(normalized) == "setup-assets.marker" { return Path.dirname(normalized) }
            if Path.basename(normalized) == "InstallerAssets" { return normalized }
            if normalized.hasSuffix(".app") { return Path.join(normalized, "Contents", "Resources", "InstallerAssets") }
        }
        // Helper binary at <Setup.app>/Contents/Helpers/roachnet-runtime
        let executable = RuntimeBuildInfo.executablePath
        let contents = Path.dirname(Path.dirname(executable))
        let candidate = Path.join(contents, "Resources", "InstallerAssets")
        return Files.isDirectory(candidate) ? candidate : nil
    }

    // MARK: Persisted config

    func isTransientPath(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        let roots = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].map { Path.resolve($0).lowercased() }
        return roots.contains { lower.hasPrefix($0) } && lower.contains("roachnet")
    }

    func isScratchPath(_ candidate: String) -> Bool {
        if isTransientPath(candidate) { return true }
        let segments = candidate.split(separator: "/").map { $0.lowercased() }
        if segments.contains(".roachnet-setup") || segments.contains(".smoke-work") { return true }
        return JS.matches("(^|[-_.])(staging|regression|regressioncheck)([-_.]|$)", segments.last ?? "")
    }

    var preservesTransientPaths: Bool {
        !(environment["ROACHNET_INSTALLER_CONFIG_PATH"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || environment["ROACHNET_ALLOW_TRANSIENT_INSTALL_PATHS"] == "1"
    }

    func sanitize(_ config: JSON) -> JSON {
        guard config.isObject, !preservesTransientPaths else { return config.isObject ? config : .object(JSONObject()) }
        let defaultRoot = defaultInstallPath()
        let installPath = normalizeInputPath(config["installPath"] || JSON(defaultRoot))
        let wasTransient = isScratchPath(installPath)
        let root = wasTransient ? defaultRoot : installPath
        var appPath = wasTransient ? canonicalAppPath(root) : normalizeInputPath(config["installedAppPath"] || JSON(canonicalAppPath(root)))
        var storagePath = wasTransient ? Path.join(root, "storage") : normalizeInputPath(config["storagePath"] || JSON(Path.join(root, "storage")))
        if isScratchPath(appPath) || !appPath.hasPrefix(root + "/") { appPath = canonicalAppPath(root) }
        if isScratchPath(storagePath) { storagePath = Path.join(root, "storage") }
        var next = config
        next["installPath"] = JSON(root)
        next["installedAppPath"] = JSON(appPath)
        next["storagePath"] = JSON(storagePath)
        if wasTransient {
            next["setupCompletedAt"] = nil
            next["pendingLaunchIntro"] = false
            next["pendingRoachClawSetup"] = false
            next["bootstrapPending"] = false
            next["bootstrapFailureCount"] = 0
            next["lastRuntimeHealthAt"] = nil
        }
        return next
    }

    func loadPersistedConfig() -> JSON {
        synchronized {
            if let cached = persistedConfigCache { return cached }
            let explicit = !(environment["ROACHNET_INSTALLER_CONFIG_PATH"] ?? "").isEmpty
            let primary = JSON.read(contentsOf: configPath)
            let legacy = explicit || configPath == legacyConfigPath ? nil : JSON.read(contentsOf: legacyConfigPath)
            let raw = primary ?? legacy ?? .object(JSONObject())
            let sanitized = sanitize(raw)
            persistedConfigCache = sanitized
            if !explicit && (primary == nil && legacy != nil || sanitized != raw) {
                try? Files.write(sanitized.prettySerialized() + "\n", to: configPath)
            }
            return sanitized
        }
    }

    func saveConfig(_ config: JSON) {
        synchronized {
            var merged = loadPersistedConfig().merging(config)
            var object = merged.object
            for (key, value) in object where value.isUndefined { object.remove(key) }
            merged = .object(object)
            persistedConfigCache = merged
            try? Files.write(merged.prettySerialized() + "\n", to: configPath, mode: Files.privateFileMode)
        }
    }

    func installLooksPresent(_ installPath: String, appPath: String) -> Bool {
        let hasManifest = Files.exists(Path.join(installPath, SetupEngine.installManifestName))
        let hasLegacyLauncher = Files.exists(Path.join(installPath, "scripts", "run-roachnet-native-api.mjs"))
            || Files.exists(Path.join(installPath, "scripts", "run-roachnet.mjs"))
        return (hasManifest || hasLegacyLauncher) && Files.exists(appPath)
    }

    static func generateToken() -> String { JS.randomHex(32) + JS.randomHex(32) }

    /// Mirrors `getDefaultConfig(overrides)`.
    func defaultConfig(_ overrides: JSON) -> JSON {
        let persisted = loadPersistedConfig()
        let persistedRoot = normalizeInputPath(persisted["installPath"] || JSON(defaultInstallPath()))
        let hasRootOverride = (overrides["installPath"].stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
        let hasStorageOverride = (overrides["storagePath"].stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
        let installPath = normalizeInputPath(overrides["installPath"] || persisted["installPath"] || JSON(defaultInstallPath()))
        let appPath = canonicalAppPath(installPath)
        let reusePersistedStorage = !hasRootOverride || installPath == persistedRoot
        let storagePath = normalizeInputPath(
            hasStorageOverride ? overrides["storagePath"]
                : reusePersistedStorage ? (persisted["storagePath"] || JSON(Path.join(installPath, "storage")))
                : JSON(Path.join(installPath, "storage"))
        )
        let present = installLooksPresent(installPath, appPath: appPath)
        // The install request (Setup UI toggle or `--no-roachclaw`) wins over the saved choice.
        let installRoachClaw = !overrides["installRoachClaw"].isUndefined ? overrides["installRoachClaw"].truthy
            : persisted["installRoachClaw"].isUndefined ? true : persisted["installRoachClaw"].truthy

        func bool(_ key: String, _ fallback: Bool) -> JSON {
            if !overrides[key].isUndefined { return JSON(overrides[key].truthy) }
            if !persisted[key].isUndefined { return JSON(persisted[key].truthy) }
            return JSON(fallback)
        }
        func string(_ key: String, _ fallback: String) -> JSON {
            let override = (overrides[key].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty { return JSON(override) }
            let stored = (persisted[key].stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return JSON(stored.isEmpty ? fallback : stored)
        }
        let companionPort: Double = {
            let raw = !overrides["companionPort"].isUndefined ? overrides["companionPort"] : persisted["companionPort"]
            let number = (raw || 38111).jsNumber
            return JSCoercion.isSafeInteger(number) && number > 0 && number <= 65535 ? number : 38111
        }()
        let releaseChannel = string("releaseChannel", "stable").stringValue!
        var config: JSON = [
            "installPath": JSON(installPath),
            "installedAppPath": JSON(appPath),
            "appInstallPath": JSON(appPath),
            "storagePath": JSON(storagePath),
            "installProfile": string("installProfile", "standard"),
            "sourceMode": "bundled",
            "useDockerContainerization": false,
            "installRoachClaw": JSON(installRoachClaw),
            "roachClawDefaultModel": string("roachClawDefaultModel", SetupEngine.defaultModel),
            "companionEnabled": bool("companionEnabled", true),
            "companionHost": string("companionHost", "127.0.0.1"),
            "companionPort": JSON(companionPort),
            "companionToken": string("companionToken", SetupEngine.generateToken()),
            "companionAdvertisedURL": overrides["companionAdvertisedURL"] || persisted["companionAdvertisedURL"] || "",
            "autoInstallDependencies": false,
            "autoLaunch": bool("autoLaunch", true),
            "releaseChannel": JSON(["stable", "beta", "alpha"].contains(releaseChannel) ? releaseChannel : "stable"),
            "updateBaseUrl": overrides["updateBaseUrl"] || persisted["updateBaseUrl"] || "",
            "autoCheckUpdates": bool("autoCheckUpdates", true),
            "autoDownloadUpdates": JSON(persisted["autoDownloadUpdates"].truthy),
            "launchAtLogin": bool("launchAtLogin", false),
            "dryRun": bool("dryRun", false),
            "distributedInferenceBackend": string("distributedInferenceBackend", "disabled"),
            "exoBaseUrl": string("exoBaseUrl", "http://127.0.0.1:52415"),
            "exoModelId": overrides["exoModelId"] || persisted["exoModelId"] || "",
            "bootstrapPending": JSON(persisted["bootstrapPending"].truthy),
            "bootstrapFailureCount": JSON((persisted["bootstrapFailureCount"] || 0).jsNumber),
            "lastRuntimeHealthAt": persisted["lastRuntimeHealthAt"] || nil,
            "setupCompletedAt": present ? (persisted["setupCompletedAt"] || nil) : nil,
            "pendingLaunchIntro": JSON(present && persisted["pendingLaunchIntro"].truthy),
            "pendingRoachClawSetup": JSON(present && persisted["pendingRoachClawSetup"].truthy),
            "roachClawOnboardingCompletedAt": persisted["roachClawOnboardingCompletedAt"] || nil,
            "introCompletedAt": persisted["introCompletedAt"] || nil,
            "lastOpenedMode": persisted["lastOpenedMode"] || "setup",
            "preferredShell": "native",
        ]
        // Persisted keys the engine does not model (app-owned settings) survive.
        for (key, value) in persisted.object where config[key].isUndefined { config[key] = value }
        return config
    }

    // MARK: Preflight

    func preflight(_ config: JSON) -> [JSON] {
        let installPath = normalizeInputPath(config["installPath"])
        // Test hosts (Linux CI) may exercise the install lane without Apple hardware.
        let hostOverride = environment["ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST"] == "1"
        let appleSilicon = SetupPlatform.hardwareIsAppleSilicon || hostOverride
        let os = SetupPlatform.osVersion
        let osOK = hostOverride || !SetupPlatform.isMacOS || os.majorVersion >= SetupEngine.minimumMacOSMajor
        let required = requiredFreeBytes(installRoachClaw: config["installRoachClaw"].truthy)
        let free = SetupPlatform.availableBytes(at: installPath)
        let writable = SetupPlatform.isWritableDirectoryTarget(installPath) && !SetupPlatform.isLikelyInstallerMedia(installPath)
        let recommendation = SetupPlatform.recommendedModel()
        let memory = Int64(SetupPlatform.memoryBytes)
        return [
            [
                "id": "apple-silicon", "label": "Apple Silicon", "available": JSON(appleSilicon), "required": true,
                "version": JSON(SetupPlatform.chipName), "minimumVersion": "M1", "needsUpdate": false, "detectionPending": false,
                "notes": JSON(appleSilicon
                    ? (SetupPlatform.isTranslated ? "Running under Rosetta; RoachNet itself runs natively." : "Native Apple Silicon detected.")
                    : "RoachNet requires a Mac with Apple Silicon (M1 or later)."),
            ],
            [
                "id": "macos", "label": "macOS", "available": JSON(osOK), "required": true,
                "version": JSON(SetupPlatform.osVersionString), "minimumVersion": JSON("\(SetupEngine.minimumMacOSMajor).0"),
                "needsUpdate": JSON(!osOK), "detectionPending": false,
                "notes": JSON(osOK ? "macOS \(SetupPlatform.osVersionString) is supported." : "Update to macOS \(SetupEngine.minimumMacOSMajor) Sonoma or later."),
            ],
            [
                "id": "disk-space", "label": "Free space", "available": JSON(free >= required), "required": true,
                "version": JSON(SetupPlatform.formatBytes(free)), "minimumVersion": JSON(SetupPlatform.formatBytes(required)),
                "needsUpdate": false, "detectionPending": false,
                "notes": JSON(free >= required
                    ? "\(SetupPlatform.formatBytes(free)) free on the install volume."
                    : "Free up space or pick another install folder; this install needs about \(SetupPlatform.formatBytes(required))."),
            ],
            [
                "id": "install-location", "label": "Install folder", "available": JSON(writable), "required": true,
                "version": nil, "minimumVersion": nil, "needsUpdate": false, "detectionPending": false,
                "notes": JSON(writable
                    ? "RoachNet installs into a self-contained folder without admin rights."
                    : "Choose a writable folder on this Mac (not the RoachNet Setup disk image)."),
            ],
            [
                "id": "memory", "label": "Memory", "available": true, "required": false,
                "version": JSON(SetupPlatform.formatBytes(memory)), "minimumVersion": "8 GB", "needsUpdate": false, "detectionPending": false,
                "notes": JSON("Recommended first RoachClaw model for this Mac: \(recommendation.model) (\(recommendation.tier) tier)."),
            ],
        ]
    }

    func systemDescription() -> JSON {
        let recommendation = SetupPlatform.recommendedModel()
        return [
            "platform": JSON(Host.platform),
            "arch": JSON(Host.arch),
            "osLabel": JSON(SetupPlatform.isMacOS ? "macOS \(SetupPlatform.osVersionString)" : Host.platform),
            "chip": JSON(SetupPlatform.chipName),
            "isAppleSilicon": JSON(SetupPlatform.hardwareIsAppleSilicon),
            "translated": JSON(SetupPlatform.isTranslated),
            "memoryBytes": JSON(Double(SetupPlatform.memoryBytes)),
            "recommendedModel": JSON(recommendation.model),
            "memoryTier": JSON(recommendation.tier),
            "packageManager": ["id": "native", "label": "Native installer (no package manager)"],
            "currentWorkspaceSourceAvailable": true,
            "runtime": "native-swift",
        ]
    }

    // MARK: State

    func overrides(from url: WebURL) -> JSON {
        var object = JSONObject()
        let strings = ["installPath", "installedAppPath", "storagePath", "installProfile", "roachClawDefaultModel", "companionHost",
                       "companionToken", "companionAdvertisedURL", "releaseChannel", "updateBaseUrl", "distributedInferenceBackend",
                       "exoBaseUrl", "exoModelId"]
        for key in strings { if let value = url.queryParameter(key), !value.isEmpty { object[key] = JSON(value) } }
        for key in ["autoInstallDependencies", "useDockerContainerization", "installRoachClaw", "companionEnabled", "autoLaunch",
                    "autoCheckUpdates", "launchAtLogin", "dryRun"] {
            if let value = url.queryParameter(key) { object[key] = JSON(value == "true") }
        }
        if let port = url.queryParameter("companionPort") { object["companionPort"] = JSON(JSCoercion.number(fromString: port)) }
        return .object(object)
    }

    public func state(_ url: WebURL) -> JSON {
        let config = defaultConfig(overrides(from: url))
        let installPath = normalizeInputPath(config["installPath"])
        let appPath = normalizeInputPath(config["installedAppPath"] || JSON(canonicalAppPath(installPath)))
        let (active, last) = synchronized { (activeTask, lastCompletedTask) }
        return [
            "system": systemDescription(),
            "config": config,
            "installPath": JSON(installPath),
            "nativeApp": ["installPath": JSON(appPath), "installed": JSON(Files.exists(appPath)), "kind": "bundle"],
            "installLooksReady": JSON(installLooksPresent(installPath, appPath: appPath)),
            "containerRuntime": [
                "available": false, "daemonRunning": false, "composeAvailable": false, "ready": false,
                "detectionPending": false, "type": nil,
                "docs": ["desktop": "RoachNet runs natively; containers are not used."],
            ],
            "dependencies": .array(preflight(config)),
            "activeTask": active ?? .null,
            "lastCompletedTask": last ?? .null,
            "sourceModes": [[
                "id": "bundled", "label": "Install bundled RoachNet",
                "description": "Install the RoachNet app and contained tooling shipped inside RoachNet Setup.",
                "available": true,
            ]],
        ]
    }

    // MARK: Task bookkeeping

    private func newTask() -> JSON {
        let now = JS.isoNow()
        return [
            "id": JSON(JS.randomUUID()), "status": "running", "phase": "Queued", "currentStep": "Waiting to start.",
            "progress": 0, "startedAt": JSON(now), "updatedAt": JSON(now), "finishedAt": nil, "logs": [], "error": nil, "result": nil,
        ]
    }

    func updateTask(_ mutate: (inout JSON) -> Void) {
        synchronized {
            guard var task = activeTask else { return }
            mutate(&task)
            task["updatedAt"] = JSON(JS.isoNow())
            activeTask = task
        }
    }

    func log(_ message: String) {
        let line = "[\(JS.isoNow())] \(redact(message))"
        updateTask { task in
            var logs = task["logs"].array
            logs.append(JSON(line))
            if logs.count > SetupEngine.taskLogLimit { logs.removeFirst(logs.count - SetupEngine.taskLogLimit) }
            task["logs"] = .array(logs)
        }
        RuntimeLog.write("setup: \(redact(message))")
        onLog?(line)
    }

    func setPhase(_ phase: String, _ progress: Int) {
        updateTask { task in
            task["phase"] = JSON(phase)
            task["progress"] = JSON(progress)
            task["currentStep"] = JSON("\(phase) started.")
        }
        log("Phase: \(phase)")
    }

    func setStep(_ step: String) { updateTask { $0["currentStep"] = JSON(step) } }

    /// Keeps logs and errors free of machine-specific paths.
    func redact(_ message: String) -> String {
        var output = message
        for path in [home].sorted(by: { $0.count > $1.count }) where !path.isEmpty && path != "/" {
            output = output.replacingOccurrences(of: path, with: "~")
        }
        return output
    }

    // MARK: Install workflow

    struct InstallPlan {
        let installPath: String
        let appPath: String
        let storagePath: String
        let installRoachClaw: Bool
        let autoLaunch: Bool
        let config: JSON
    }

    public func startInstall(_ payload: JSON) throws -> JSON {
        try startInstall(payload, synchronous: false)
    }

    /// Headless install used by `roachnet-runtime --install` (Homebrew, scripted
    /// and MDM installs). Runs the same staged workflow as the Setup app and
    /// returns the finished task.
    public func installSynchronously(_ payload: JSON) throws -> JSON {
        _ = try startInstall(payload, synchronous: true)
        return synchronized { lastCompletedTask ?? .null }
    }

    func startInstall(_ payload: JSON, synchronous: Bool) throws -> JSON {
        let config = defaultConfig(payload)
        if config["dryRun"].truthy {
            var preview = newTask()
            preview["status"] = "completed"
            preview["finishedAt"] = JSON(JS.isoNow())
            preview["result"] = ["installPath": config["installPath"], "appPath": config["installedAppPath"], "url": nil]
            preview["logs"] = ["Preview mode is enabled. No changes were made."]
            synchronized { lastCompletedTask = preview }
            return ["ok": true, "task": preview]
        }
        try synchronized {
            if activeTask?["status"].stringValue == "running" {
                throw requestError("A setup task is already running. Wait for it to finish before starting another one.", 409)
            }
            activeTask = newTask()
            lastCompletedTask = nil
        }
        let plan = InstallPlan(
            installPath: normalizeInputPath(config["installPath"]),
            appPath: canonicalAppPath(normalizeInputPath(config["installPath"])),
            storagePath: normalizeInputPath(config["storagePath"] || JSON(Path.join(normalizeInputPath(config["installPath"]), "storage"))),
            installRoachClaw: config["installRoachClaw"].truthy,
            autoLaunch: config["autoLaunch"].truthy,
            config: config
        )
        if synchronous {
            runInstall(plan)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { self.runInstall(plan) }
        }
        return ["ok": true]
    }

    func runInstall(_ plan: InstallPlan) {
        var stagingRoot: String?
        do {
            saveConfig(plan.config)
            try Files.mkdirp(Path.dirname(plan.installPath))
            recoverInterruptedInstall(finalRoot: plan.installPath)

            setPhase("Inspecting system", 5)
            let checks = preflight(plan.config)
            log("Detected \(SetupPlatform.isMacOS ? "macOS \(SetupPlatform.osVersionString)" : Host.platform) on \(SetupPlatform.chipName) with \(SetupPlatform.formatBytes(Int64(SetupPlatform.memoryBytes))) memory.")
            let recommendation = SetupPlatform.recommendedModel()
            log("RAM-aware RoachClaw recommendation: \(recommendation.model) (\(recommendation.tier)).")

            setPhase("Validating contained install lane", 12)
            for check in checks where check["required"].truthy && !check["available"].truthy {
                throw RuntimeError(check["notes"].jsString)
            }
            log("Install volume has \(checks.first { $0["id"].stringValue == "disk-space" }?["version"].jsString ?? "unknown") free.")

            setPhase("Staging RoachNet", 24)
            let staging = Path.join(Path.dirname(plan.installPath), "\(Path.basename(plan.installPath)).staging-\(JS.randomHex(8))")
            stagingRoot = staging
            try Files.mkdirp(staging)
            for directory in ["app", "bin", "runtime"] { try Files.mkdirp(Path.join(staging, directory)) }
            log("Staging the install beside the target folder on the same volume.")

            setPhase("Preparing RoachClaw", 38)
            if plan.installRoachClaw {
                log("RoachClaw runs on the native RoachInference engine inside roachnet-runtime; no separate model runner is installed.")
            } else {
                log("Skipping RoachClaw setup because RoachClaw is disabled for this install.")
            }

            setPhase("Preparing contained runtime", 52)
            try writeInstallManifest(stagingRoot: staging, plan: plan)

            setPhase("Installing native desktop app", 64)
            let stagedApp = Path.join(staging, "app", "RoachNet.app")
            try installDesktopApp(into: stagedApp)

            setPhase("Verifying contained runtime", 76)
            try smokeTestRuntime(appPath: stagedApp, scratchRoot: Path.join(staging, ".smoke-work"))

            setPhase("Finalizing install", 88)
            terminateRunningRoachNet(plan)
            try finalizeInstallRoot(staging: staging, finalRoot: plan.installPath, storagePath: plan.storagePath)
            stagingRoot = nil
            try Files.mkdirp(plan.storagePath)

            setPhase("Arming RoachTail local alias", 94)
            try provisionLocalAlias()

            let finishedAt = JS.isoNow()
            var completedConfig = plan.config
            completedConfig["installedAppPath"] = JSON(plan.appPath)
            completedConfig["setupCompletedAt"] = JSON(finishedAt)
            completedConfig["pendingLaunchIntro"] = true
            completedConfig["pendingRoachClawSetup"] = JSON(plan.installRoachClaw)
            completedConfig["roachClawOnboardingCompletedAt"] = nil
            completedConfig["introCompletedAt"] = nil
            completedConfig["preferredShell"] = "native"
            completedConfig["bootstrapPending"] = false
            completedConfig["bootstrapFailureCount"] = 0
            saveConfig(completedConfig)

            if plan.autoLaunch {
                setPhase("Launching RoachNet", 98)
                SetupPlatform.open(plan.appPath)
                log("RoachNet launched.")
            }

            updateTask { task in
                task["status"] = "completed"
                task["progress"] = 100
                task["currentStep"] = "RoachNet is installed and ready."
                task["finishedAt"] = JSON(finishedAt)
                task["result"] = ["installPath": JSON(plan.installPath), "appPath": JSON(plan.appPath), "url": nil]
            }
            log("RoachNet setup completed successfully.")
        } catch {
            let message = sanitizeError(error, plan)
            updateTask { task in
                task["status"] = "failed"
                task["currentStep"] = "Setup failed. Fix the issue and run install again."
                task["finishedAt"] = JSON(JS.isoNow())
                task["error"] = JSON(message)
            }
            log("Setup failed: \(message)")
            if let stagingRoot {
                if environment["ROACHNET_SETUP_KEEP_STAGED_FAILURE"] == "1" {
                    log("Preserving the staged install for debugging.")
                } else {
                    Files.remove(stagingRoot)
                    log("Removed the staged install so this Mac can retry setup cleanly.")
                }
            }
        }
        synchronized {
            lastCompletedTask = activeTask
            activeTask = nil
        }
    }

    func sanitizeError(_ error: Error, _ plan: InstallPlan) -> String {
        let raw = "\(error)"
        if JS.matches("ENOSPC|no space left on device", raw, caseInsensitive: true) {
            let required = requiredFreeBytes(installRoachClaw: plan.installRoachClaw)
            return "RoachNet ran out of disk space while staging the install. Free up space or choose another folder; this install expects about \(SetupPlatform.formatBytes(required)) free."
        }
        var message = raw
        for path in [plan.installPath, plan.storagePath, plan.appPath].sorted(by: { $0.count > $1.count }) {
            message = message.replacingOccurrences(of: path, with: "RoachNet root")
        }
        return redact(message)
    }

    // MARK: Steps

    /// Free-space floor. Test hosts (unsupported-host mode only) may lower it.
    func requiredFreeBytes(installRoachClaw: Bool) -> Int64 {
        if environment["ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST"] == "1",
           let override = environment["ROACHNET_SETUP_TEST_MIN_FREE_BYTES"].flatMap(Int64.init) {
            return override
        }
        return installRoachClaw ? SetupEngine.minimumFreeWithRoachClaw : SetupEngine.minimumFreeBase
    }

    /// True while an install task is running; the host defers exit until it finishes
    /// so quitting Setup can never interrupt the root swap.
    public var isInstalling: Bool {
        synchronized { activeTask?["status"].stringValue == "running" }
    }

    /// Cleans up after a run that was killed (power loss, force quit) before it
    /// could tidy up: removes stale staging folders and, if the install root is
    /// missing but a pre-swap backup exists, puts the backup back.
    func recoverInterruptedInstall(finalRoot: String) {
        let parent = Path.dirname(finalRoot)
        let base = Path.basename(finalRoot)
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        for name in siblings where name.hasPrefix("\(base).staging-") {
            Files.remove(Path.join(parent, name))
            log("Removed an unfinished staged install left by an earlier run.")
        }
        let backups = siblings.filter { $0.hasPrefix("\(base).backup-") }.sorted()
        guard let newest = backups.last else { return }
        if !Files.exists(finalRoot) {
            do {
                try SetupPlatform.moveItem(Path.join(parent, newest), finalRoot)
                log("Restored the previous install that an interrupted upgrade had moved aside.")
            } catch {
                log("An earlier upgrade left a backup at \(newest) that could not be restored automatically: \(error)")
            }
        } else {
            log("An earlier upgrade left \(backups.count == 1 ? "a backup" : "\(backups.count) backups") beside the install (\(newest)). It is kept in case it holds storage you need.")
        }
    }

    /// Points the RoachTail hostname at loopback. Best effort unless
    /// ROACHNET_REQUIRE_LOCAL_ALIAS=1; only the system hosts file may prompt.
    func provisionLocalAlias() throws {
        let explicitHostsFile = environment["ROACHNET_HOSTS_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard SetupPlatform.isMacOS || !explicitHostsFile.isEmpty else { return }
        let hostsFile = explicitHostsFile.isEmpty ? "/etc/hosts" : explicitHostsFile
        let hostname = RoachTailHostname.hostname(environment: environment)
        log("Provisioning the RoachTail local alias \(hostname) via \(hostsFile)...")
        do {
            let outcome = try RoachTailHostname.provision(
                hostname: hostname,
                hostsFile: hostsFile,
                allowPrivilegePrompt: hostsFile == "/etc/hosts"
            )
            log(outcome.changed
                ? "RoachTail local alias \(hostname) now points at the contained desktop lane."
                : "RoachTail local alias \(hostname) was already in place.")
        } catch {
            log("RoachTail local alias could not be provisioned automatically. \(error)")
            if environment["ROACHNET_REQUIRE_LOCAL_ALIAS"] == "1" { throw error }
        }
    }

    func writeInstallManifest(stagingRoot: String, plan: InstallPlan) throws {
        let manifest: JSON = [
            "schema": "org.roachnet.install.v1",
            "version": JSON(version),
            "runtime": "native-swift",
            "installedAt": JSON(JS.isoNow()),
            "appPath": JSON(plan.appPath),
            "storagePath": JSON(plan.storagePath),
            "roachClaw": JSON(plan.installRoachClaw),
            "host": [
                "arch": JSON(Host.arch),
                "os": JSON(SetupPlatform.osVersionString),
                "memoryTier": JSON(SetupPlatform.recommendedModel().tier),
            ],
        ]
        try Files.writePrettyJSON(manifest, to: Path.join(stagingRoot, SetupEngine.installManifestName))
        log("Wrote the install manifest.")
    }

    /// Locates the RoachNet.app payload shipped with RoachNet Setup.
    func resolveAppSource(scratch: String) throws -> String {
        var candidates: [String] = []
        if let explicit = environment["ROACHNET_SETUP_DESKTOP_APP"], !explicit.isEmpty { candidates.append(Path.resolve(explicit)) }
        if let assets = installerAssetsPath {
            candidates.append(Path.join(assets, "RoachNet.app"))
            candidates.append(Path.join(assets, "RoachNet-\(version)-mac-arm64.zip"))
            for entry in Files.entries(assets) where entry.name.hasPrefix("RoachNet-") && entry.name.hasSuffix(".zip") && entry.name.contains("mac-arm64") {
                candidates.append(Path.join(assets, entry.name))
            }
            // Setup.app sitting next to RoachNet.app on the disk image.
            let setupBundle = Path.dirname(Path.dirname(Path.dirname(assets)))
            candidates.append(Path.join(Path.dirname(setupBundle), "RoachNet.app"))
        }
        for candidate in candidates where Files.exists(candidate) {
            if candidate.hasSuffix(".app") {
                log("Using the bundled RoachNet app payload.")
                return candidate
            }
            if candidate.hasSuffix(".zip") {
                log("Unpacking the bundled RoachNet app archive.")
                let extractRoot = Path.join(scratch, "app-archive")
                try SetupPlatform.extractZip(candidate, to: extractRoot)
                if let found = findBundle(named: "RoachNet.app", in: extractRoot, depth: 0) { return found }
                throw RuntimeError("The bundled RoachNet archive did not contain RoachNet.app.")
            }
        }
        throw RuntimeError("RoachNet Setup could not find the RoachNet app payload. Download a fresh copy of RoachNet Setup and try again.")
    }

    func findBundle(named name: String, in root: String, depth: Int) -> String? {
        if depth > 3 { return nil }
        for entry in Files.entries(root) {
            let full = Path.join(root, entry.name)
            if entry.name == name { return full }
            if entry.isDirectory, let found = findBundle(named: name, in: full, depth: depth + 1) { return found }
        }
        return nil
    }

    func installDesktopApp(into stagedApp: String) throws {
        let scratch = Path.join(Path.dirname(Path.dirname(stagedApp)), ".setup-scratch")
        defer { Files.remove(scratch) }
        let source = try resolveAppSource(scratch: scratch)
        try SetupPlatform.copyDirectory(source, to: stagedApp)
        let helper = Path.join(stagedApp, "Contents", "Helpers", appHelperName)
        if Files.exists(helper) {
            log("Native runtime helper is present in the app bundle.")
        } else {
            log("This RoachNet build has no native runtime helper; it will fall back to its compatibility launcher.")
        }
        SetupPlatform.prepareForLaunch(stagedApp, log: log)
    }

    /// Boots the staged app's native runtime against scratch storage and waits for health.
    func smokeTestRuntime(appPath: String, scratchRoot: String) throws {
        let helper = Path.join(appPath, "Contents", "Helpers", appHelperName)
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            log("Skipped runtime verification: no native runtime helper in this app build.")
            return
        }
        defer { Files.remove(scratchRoot) }
        try Files.mkdirp(scratchRoot)
        let infoPath = Path.join(scratchRoot, "server-info.json")
        var environment = self.environment
        environment["ROACHNET_STORAGE_PATH"] = Path.join(scratchRoot, "storage")
        environment["ROACHNET_RUNTIME_STATE_ROOT"] = Path.join(scratchRoot, "state")
        environment["ROACHNET_SERVER_INFO_FILE"] = infoPath
        environment["ROACHNET_COMPANION_ENABLED"] = "0"
        environment["ROACHNET_OPEN_UPDATES"] = "0"
        environment["OLLAMA_BASE_URL"] = "http://127.0.0.1:9"
        environment["HOST"] = "127.0.0.1"
        environment["PORT"] = "0"
        environment.removeValue(forKey: "ROACHNET_SETUP_READY_FILE")
        let dataRoot = Path.join(appPath, "Contents", "Resources", "RoachNetRuntimeData")
        if Files.isDirectory(dataRoot) { environment["ROACHNET_REPO_ROOT"] = dataRoot }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < deadline { usleep(100_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !process.isRunning {
                throw RuntimeError("The installed RoachNet runtime exited during verification (status \(process.terminationStatus)).")
            }
            if let info = JSON.read(contentsOf: infoPath), let health = info["healthUrl"].stringValue,
               let response = try? HTTPClient.request(health, timeoutMs: 2_000), response.ok
            {
                log("Native runtime answered its health check.")
                return
            }
            usleep(250_000)
        }
        throw RuntimeError("The installed RoachNet runtime did not become healthy during verification.")
    }

    func terminateRunningRoachNet(_ plan: InstallPlan) {
        var closed = 0
        for pattern in ["/RoachNet.app/Contents/MacOS/RoachNetApp", "\(plan.appPath)/Contents/Helpers/\(appHelperName)",
                        Path.join(plan.installPath, "scripts", "run-roachnet-native-api.mjs"),
                        Path.join(plan.installPath, "scripts", "roachnet-companion-server.mjs")] {
            if SetupPlatform.terminateProcesses(matching: JS.replace("[\\\\^$.*+?()\\[\\]{}|]", in: pattern, with: "\\\\$0")) { closed += 1 }
        }
        if closed > 0 { log("Closed running RoachNet processes before replacing the installed copy.") }
    }

    func isInside(_ candidate: String, _ root: String) -> Bool {
        let relative = Path.relative(from: root, to: candidate)
        return !relative.isEmpty && !relative.hasPrefix("..") && !Path.isAbsolute(relative)
    }

    /// Swaps the staged root into place, carrying user storage across and
    /// restoring the previous install if anything fails.
    func finalizeInstallRoot(staging: String, finalRoot: String, storagePath: String) throws {
        let backup = Files.exists(finalRoot) ? Path.join(Path.dirname(finalRoot), "\(Path.basename(finalRoot)).backup-\(Int(JS.nowMs()))") : nil
        if let backup {
            log("Moving the previous install aside.")
            try SetupPlatform.moveItem(finalRoot, backup)
        }
        do {
            try SetupPlatform.moveItem(staging, finalRoot)
            var storageNeedsRecovery = false
            if let backup, isInside(storagePath, finalRoot) {
                let relative = Path.relative(from: finalRoot, to: storagePath)
                let previousStorage = Path.join(backup, relative)
                if Files.exists(previousStorage) {
                    do {
                        Files.remove(storagePath)
                        try SetupPlatform.moveItem(previousStorage, storagePath)
                        log("Existing RoachNet storage preserved.")
                    } catch {
                        storageNeedsRecovery = true
                        log("Could not move previous storage automatically: \(error)")
                    }
                }
            }
            if let backup {
                // Runners bundled by older releases (runtime/vendor/ollama) are not carried
                // forward: 1.1+ serves models natively. Models stay in storage/models.
                // Anything at the top of the old root that setup does not manage stays: the
                // Homebrew-installed `setup/RoachNet Setup.app`, or files the user put there.
                let managed: Set<String> = ["app", "bin", "runtime", SetupEngine.installManifestName, ".smoke-work"]
                for name in (try? FileManager.default.contentsOfDirectory(atPath: backup)) ?? []
                where !managed.contains(name) && !Files.exists(Path.join(finalRoot, name)) {
                    do {
                        try SetupPlatform.moveItem(Path.join(backup, name), Path.join(finalRoot, name))
                    } catch {
                        storageNeedsRecovery = true
                        log("Could not carry \(name) into the new install: \(error)")
                    }
                }
            }
            if let backup {
                if storageNeedsRecovery {
                    log("The previous install was kept beside the new one so storage can be recovered manually.")
                } else {
                    Files.remove(backup)
                }
            }
        } catch {
            if let backup, Files.exists(backup) {
                Files.remove(finalRoot)
                try? SetupPlatform.moveItem(backup, finalRoot)
                log("Restored the previous install after a failed swap.")
            }
            throw error
        }
    }

    // MARK: Launch

    public func launch(_ payload: JSON) throws -> JSON {
        let config = defaultConfig(payload)
        let installPath = normalizeInputPath(payload["installPath"] || config["installPath"])
        let appPath = normalizeInputPath(payload["installedAppPath"] || config["installedAppPath"] || JSON(canonicalAppPath(installPath)))
        guard Files.exists(appPath) else {
            throw requestError("RoachNet is not installed at the selected location yet. Run setup first.", 400)
        }
        var next = config
        next["installPath"] = JSON(installPath)
        next["installedAppPath"] = JSON(appPath)
        next["lastOpenedMode"] = "app"
        next["preferredShell"] = "native"
        saveConfig(next)
        SetupPlatform.open(appPath)
        return ["ok": true, "launched": "native-app", "installedAppPath": JSON(appPath)]
    }

    // MARK: HTTP

    public func handle(_ request: inout HTTPRequest) -> HTTPResponse {
        let url = WebURL(request.target, base: WebURL("http://localhost")) ?? WebURL("http://localhost/")!
        func body() throws -> JSON {
            let data: Data
            do { data = try request.body() } catch { throw requestError("Request body is too large.", 413) }
            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return .object(JSONObject()) }
            guard NativeRuntime.declaresJSONBody(request) else {
                throw requestError("Request body must be sent as application/json.", 415)
            }
            do { return try JSON.parse(raw) } catch { throw requestError("Request body must be valid JSON.", 400) }
        }
        do {
            // Same CSRF / DNS-rebinding stance as the runtime API: the setup
            // service can rewrite the install root and companion token.
            guard NativeRuntime.isTrustedLoopbackHost(request.header("host")) else {
                return .json(403, ["error": "Setup requests must use a loopback Host."])
            }
            guard NativeRuntime.isTrustedLoopbackOrigin(request.header("origin")) else {
                return .json(403, ["error": "Setup requests from other sites are refused."])
            }
            switch (request.method, url.pathname) {
            case ("GET", "/api/state"):
                return .json(200, state(url))
            case ("POST", "/api/config"):
                let config = defaultConfig(try body())
                saveConfig(config)
                return .json(200, ["ok": true, "config": config])
            case ("POST", "/api/install"):
                return .json(200, try startInstall(try body()))
            case ("POST", "/api/launch"):
                return .json(200, try launch(try body()))
            case ("POST", "/api/container-runtime/start"):
                return .json(400, ["ok": false, "error": "RoachNet runs natively and does not use a container runtime."])
            case ("GET", "/health"), ("GET", "/api/health"):
                return .json(200, ["status": "ok", "runtime": "native-swift", "mode": "setup"])
            default:
                return .json(404, ["error": JSON("No setup endpoint for \(request.method) \(url.pathname)")])
            }
        } catch let error as RuntimeError {
            return .json(error.statusCode == 500 ? 400 : error.statusCode, ["error": JSON(error.message)])
        } catch {
            return .json(400, ["error": JSON("\(error)")])
        }
    }

    /// Starts the loopback setup service and writes the ready file the Setup
    /// app waits for.
    public func serve() throws -> LoopbackHTTPServer {
        let requestedPort = UInt16(environment["ROACHNET_SETUP_PORT"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: requestedPort, maxBodyBytes: 1024 * 1024) { [self] request in
            handle(&request)
        }
        try server.start()
        let url = "http://127.0.0.1:\(server.port)"
        if let ready = environment["ROACHNET_SETUP_READY_FILE"], !ready.isEmpty {
            let readyPayload: JSON = ["url": JSON(url), "pid": JSON(Int(getpid())), "startedAt": JSON(JS.isoNow()), "runtime": "native-swift"]
            try Files.write(readyPayload.prettySerialized() + "\n", to: ready)
        }
        RuntimeLog.write("setup service listening on \(url)")
        return server
    }
}
