import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class SetupEngine {
    public static let minimumMacOSMajor = 14
    static let gib: Int64 = 1024 * 1024 * 1024
    static let minimumFreeBase: Int64 = 2 * gib
    static let minimumFreeWithRoachClaw: Int64 = 5 * gib
    static let defaultModel = "qwen2.5-coder:1.5b"
    static let taskLogLimit = 800
    static let installManifestName = "roachnet-install.json"

    let environment: [String: String]
    public var onLog: ((String) -> Void)?

    var moveIntoPlace: (String, String) throws -> Void = { try SetupPlatform.moveItem($0, $1) }
    var runLockCall: SetupRunLock.LockCall = { flock($0, $1) }
    let version: String
    private let lock = NSRecursiveLock()
    private var activeTask: JSON?
    private var lastCompletedTask: JSON?
    private var persistedConfigCache: JSON?
    var appHelperName: String { RuntimeBuildInfo.executableName }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        version: String = RuntimeConfiguration.shared.version
    ) {
        self.environment = environment
        self.version = version
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

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
        if let explicit = environment["ROACHNET_SHARED_APP_DATA_DIR"], !explicit.isEmpty {
            return Path.resolve(explicit)
        }
        return SetupPlatform.isMacOS
            ? Path.join(home, "Library", "Application Support", "roachnet")
            : Path.join(environment["XDG_CONFIG_HOME"] ?? Path.join(home, ".config"), "roachnet")
    }

    var configPath: String {
        if let explicit = environment["ROACHNET_INSTALLER_CONFIG_PATH"], !explicit.isEmpty { return explicit }
        return Path.join(sharedAppDataDirectory, "roachnet-installer.json")
    }

    var legacyConfigPath: String { Path.join(home, ".roachnet-setup.json") }

    public var setupLogPath: String { Path.join(Path.dirname(configPath), "setup.log") }

    public var setupLockPath: String { Path.join(Path.dirname(configPath), "setup.lock") }

    var installerAssetsPath: String? {
        if let explicit = environment["ROACHNET_SETUP_APP_BUNDLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty
        {
            let normalized = Path.resolve(explicit)
            if Path.basename(normalized) == "setup-assets.marker" { return Path.dirname(normalized) }
            if Path.basename(normalized) == "InstallerAssets" { return normalized }
            if normalized.hasSuffix(".app") { return Path.join(normalized, "Contents", "Resources", "InstallerAssets") }
        }
        let executable = RuntimeBuildInfo.executablePath
        let contents = Path.dirname(Path.dirname(executable))
        let candidate = Path.join(contents, "Resources", "InstallerAssets")
        return Files.isDirectory(candidate) ? candidate : nil
    }

    func isTransientPath(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        let roots = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].map {
            Path.resolve($0).lowercased()
        }
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
        var appPath =
            wasTransient
            ? canonicalAppPath(root) : normalizeInputPath(config["installedAppPath"] || JSON(canonicalAppPath(root)))
        var storagePath =
            wasTransient
            ? Path.join(root, "storage") : normalizeInputPath(config["storagePath"] || JSON(Path.join(root, "storage")))
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

    func loadPersistedConfig(writeBack: Bool = true) -> JSON {
        synchronized {
            if let cached = persistedConfigCache { return cached }
            let explicit = !(environment["ROACHNET_INSTALLER_CONFIG_PATH"] ?? "").isEmpty
            let primary = JSON.read(contentsOf: configPath)
            let legacy = explicit || configPath == legacyConfigPath ? nil : JSON.read(contentsOf: legacyConfigPath)
            let raw = primary ?? legacy ?? .object(JSONObject())
            let sanitized = sanitize(raw)
            persistedConfigCache = sanitized
            if writeBack && !explicit && (primary == nil && legacy != nil || sanitized != raw) {
                try? Files.write(sanitized.prettySerialized() + "\n", to: configPath, mode: Files.privateFileMode)
            }
            return sanitized
        }
    }

    func saveConfig(_ config: JSON) {
        synchronized {
            var merged = loadPersistedConfig(writeBack: false).merging(config)
            var object = merged.object
            for (key, value) in object where value.isUndefined { object.remove(key) }
            merged = .object(object)
            persistedConfigCache = merged
            try? Files.write(merged.prettySerialized() + "\n", to: configPath, mode: Files.privateFileMode)
        }
    }

    func installLooksPresent(_ installPath: String, appPath: String) -> Bool {
        let hasManifest = Files.exists(Path.join(installPath, SetupEngine.installManifestName))
        let hasLegacyLauncher =
            Files.exists(Path.join(installPath, "scripts", "run-roachnet-native-api.mjs"))
            || Files.exists(Path.join(installPath, "scripts", "run-roachnet.mjs"))
        return (hasManifest || hasLegacyLauncher) && Files.exists(appPath)
    }

    static func generateToken() -> String { JS.randomHex(32) + JS.randomHex(32) }

    func defaultConfig(_ overrides: JSON, writeBack: Bool = true) -> JSON {
        let persisted = loadPersistedConfig(writeBack: writeBack)
        let persistedRoot = normalizeInputPath(persisted["installPath"] || JSON(defaultInstallPath()))
        let hasRootOverride =
            (overrides["installPath"].stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
        let hasStorageOverride =
            (overrides["storagePath"].stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
        let installPath = normalizeInputPath(
            overrides["installPath"] || persisted["installPath"] || JSON(defaultInstallPath()))
        let appPath = canonicalAppPath(installPath)
        let reusePersistedStorage = !hasRootOverride || installPath == persistedRoot
        let storagePath = normalizeInputPath(
            hasStorageOverride
                ? overrides["storagePath"]
                : reusePersistedStorage
                    ? (persisted["storagePath"] || JSON(Path.join(installPath, "storage")))
                    : JSON(Path.join(installPath, "storage"))
        )
        let present = installLooksPresent(installPath, appPath: appPath)
        let installRoachClaw =
            !overrides["installRoachClaw"].isUndefined
            ? overrides["installRoachClaw"].truthy
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
        let defaultModel = string("roachClawDefaultModel", SetupEngine.defaultModel)
        let extraModels = SetupEngine.extraModelList(
            overrides["roachClawExtraModels"].isUndefined
                ? persisted["roachClawExtraModels"] : overrides["roachClawExtraModels"],
            excluding: defaultModel.jsString
        )
        var config: JSON = [
            "installPath": JSON(installPath),
            "installedAppPath": JSON(appPath),
            "appInstallPath": JSON(appPath),
            "storagePath": JSON(storagePath),
            "installProfile": string("installProfile", "standard"),
            "sourceMode": "bundled",
            "useDockerContainerization": false,
            "installRoachClaw": JSON(installRoachClaw),
            "roachClawDefaultModel": defaultModel,
            "roachClawExtraModels": extraModels,
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
        for (key, value) in persisted.object where config[key].isUndefined { config[key] = value }
        return config
    }

    func preflight(_ config: JSON) -> [JSON] {
        let installPath = normalizeInputPath(config["installPath"])
        let hostOverride = environment["ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST"] == "1"
        let appleSilicon = SetupPlatform.hardwareIsAppleSilicon || hostOverride
        let os = SetupPlatform.osVersion
        let osOK = hostOverride || !SetupPlatform.isMacOS || os.majorVersion >= SetupEngine.minimumMacOSMajor
        let required = requiredFreeBytes(installRoachClaw: config["installRoachClaw"].truthy)
        let free = SetupPlatform.availableBytes(at: installPath)
        let writable =
            SetupPlatform.isWritableDirectoryTarget(installPath) && !SetupPlatform.isLikelyInstallerMedia(installPath)
        let recommendation = SetupPlatform.recommendedModel()
        let memory = Int64(SetupPlatform.memoryBytes)
        return [
            [
                "id": "apple-silicon", "label": "Apple Silicon", "available": JSON(appleSilicon), "required": true,
                "version": JSON(SetupPlatform.chipName), "minimumVersion": "M1", "needsUpdate": false,
                "detectionPending": false,
                "notes": JSON(
                    appleSilicon
                        ? (SetupPlatform.isTranslated
                            ? "Running under Rosetta; RoachNet itself runs natively."
                            : "Native Apple Silicon detected.")
                        : "RoachNet requires a Mac with Apple Silicon (M1 or later)."),
            ],
            [
                "id": "macos", "label": "macOS", "available": JSON(osOK), "required": true,
                "version": JSON(SetupPlatform.osVersionString),
                "minimumVersion": JSON("\(SetupEngine.minimumMacOSMajor).0"),
                "needsUpdate": JSON(!osOK), "detectionPending": false,
                "notes": JSON(
                    osOK
                        ? "macOS \(SetupPlatform.osVersionString) is supported."
                        : "Update to macOS \(SetupEngine.minimumMacOSMajor) Sonoma or later."),
            ],
            [
                "id": "disk-space", "label": "Free space", "available": JSON(free >= required), "required": true,
                "version": JSON(SetupPlatform.formatBytes(free)),
                "minimumVersion": JSON(SetupPlatform.formatBytes(required)),
                "needsUpdate": false, "detectionPending": false,
                "notes": JSON(
                    free >= required
                        ? "\(SetupPlatform.formatBytes(free)) free on the install volume."
                        : "Free up space or pick another install folder; this install needs about \(SetupPlatform.formatBytes(required))."
                ),
            ],
            [
                "id": "install-location", "label": "Install folder", "available": JSON(writable), "required": true,
                "version": nil, "minimumVersion": nil, "needsUpdate": false, "detectionPending": false,
                "notes": JSON(
                    writable
                        ? "RoachNet installs into a self-contained folder without admin rights."
                        : "Choose a writable folder on this Mac (not the RoachNet Setup disk image)."),
            ],
            [
                "id": "memory", "label": "Memory", "available": true, "required": false,
                "version": JSON(SetupPlatform.formatBytes(memory)), "minimumVersion": "8 GB", "needsUpdate": false,
                "detectionPending": false,
                "notes": JSON(
                    "Recommended first RoachClaw model for this Mac: \(recommendation.model) (\(recommendation.tier) tier)."
                ),
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

    var modelLibraryPath: String? {
        var candidates: [String] = []
        if let assets = installerAssetsPath { candidates.append(Path.join(assets, "native-models.json")) }
        candidates.append(Path.join(RuntimeConfiguration.shared.repoRoot, "collections", "native-models.json"))
        return candidates.first { Files.exists($0) }
    }

    func modelChoices() -> JSON {
        guard let path = modelLibraryPath else { return .array([]) }
        let budget = ModelLibrary.budget(memoryBytes: SetupPlatform.memoryBytes, environment: environment)
        let recommended = SetupPlatform.recommendedModel().model
        return .array(
            ModelLibrary.load(path).map { .object(ModelLibrary.json($0, budget: budget, recommended: recommended)) })
    }

    static func extraModelList(_ value: JSON, excluding defaultModel: String) -> JSON {
        let raw: [String] =
            value.isArray
            ? value.array.compactMap(\.stringValue)
            : (value.stringValue ?? "").split(separator: ",").map(String.init)
        var seen: Set<String> = [(try? NativeModelStore.normalize(defaultModel).name) ?? defaultModel]
        var names: [String] = []
        for item in raw where names.count < 16 {
            guard let name = try? NativeModelStore.normalize(item).name, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return jsonStrings(names)
    }

    func overrides(from url: WebURL) -> JSON {
        var object = JSONObject()
        let strings = [
            "installPath", "installedAppPath", "storagePath", "installProfile", "roachClawDefaultModel",
            "companionHost",
            "companionToken", "companionAdvertisedURL", "releaseChannel", "updateBaseUrl",
        ]
        for key in strings { if let value = url.queryParameter(key), !value.isEmpty { object[key] = JSON(value) } }
        for key in [
            "autoInstallDependencies", "useDockerContainerization", "installRoachClaw", "companionEnabled",
            "autoLaunch",
            "autoCheckUpdates", "launchAtLogin", "dryRun",
        ] {
            if let value = url.queryParameter(key) { object[key] = JSON(value == "true") }
        }
        if let port = url.queryParameter("companionPort") {
            object["companionPort"] = JSON(JSCoercion.number(fromString: port))
        }
        if let extras = url.queryParameter("roachClawExtraModels") { object["roachClawExtraModels"] = JSON(extras) }
        return .object(object)
    }

    public func state(_ url: WebURL) -> JSON {
        let config = defaultConfig(overrides(from: url))
        let installPath = normalizeInputPath(config["installPath"])
        let appPath = normalizeInputPath(config["installedAppPath"] || JSON(canonicalAppPath(installPath)))
        let (active, last) = synchronized { (activeTask, lastCompletedTask) }
        return [
            "system": systemDescription(),
            "models": modelChoices(),
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
            "sourceModes": [
                [
                    "id": "bundled", "label": "Install bundled RoachNet",
                    "description": "Install the RoachNet app and contained tooling shipped inside RoachNet Setup.",
                    "available": true,
                ]
            ],
        ]
    }

    private func newTask() -> JSON {
        let now = JS.isoNow()
        return [
            "id": JSON(JS.randomUUID()), "status": "running", "phase": "Queued", "currentStep": "Waiting to start.",
            "progress": 0, "startedAt": JSON(now), "updatedAt": JSON(now), "finishedAt": nil, "logs": [], "error": nil,
            "result": nil,
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

    func redact(_ message: String) -> String {
        var output = message
        for path in [home].sorted(by: { $0.count > $1.count }) where !path.isEmpty && path != "/" {
            output = output.replacingOccurrences(of: path, with: "~")
        }
        return output
    }

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

    public func installSynchronously(_ payload: JSON) throws -> JSON {
        _ = try startInstall(payload, synchronous: true)
        return synchronized { lastCompletedTask ?? .null }
    }

    func startInstall(_ payload: JSON, synchronous: Bool) throws -> JSON {
        let config = defaultConfig(payload, writeBack: false)
        if config["dryRun"].truthy {
            var preview = newTask()
            preview["status"] = "completed"
            preview["finishedAt"] = JSON(JS.isoNow())
            preview["result"] = [
                "installPath": config["installPath"], "appPath": config["installedAppPath"], "url": nil,
            ]
            preview["logs"] = ["Preview mode is enabled. No changes were made."]
            synchronized { lastCompletedTask = preview }
            return ["ok": true, "task": preview]
        }
        try synchronized {
            if activeTask != nil {
                throw requestError(
                    "A setup task is already running. Wait for it to finish before starting another one.", 409)
            }
            activeTask = newTask()
            lastCompletedTask = nil
        }
        let plan = InstallPlan(
            installPath: normalizeInputPath(config["installPath"]),
            appPath: canonicalAppPath(normalizeInputPath(config["installPath"])),
            storagePath: normalizeInputPath(
                config["storagePath"] || JSON(Path.join(normalizeInputPath(config["installPath"]), "storage"))),
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
        var runLock: SetupRunLock?
        defer { withExtendedLifetime(runLock) {} }
        do {
            runLock = try SetupRunLock(path: setupLockPath, lockCall: runLockCall)
            try Files.mkdirp(Path.dirname(plan.installPath))
            if case .restoreFailed(let problem) = recoverInterruptedInstall(
                finalRoot: plan.installPath, removeStaging: true)
            {
                throw problem
            }
            saveConfig(plan.config)

            setPhase("Inspecting system", 5)
            let checks = preflight(plan.config)
            log(
                "Detected \(SetupPlatform.isMacOS ? "macOS \(SetupPlatform.osVersionString)" : Host.platform) on \(SetupPlatform.chipName) with \(SetupPlatform.formatBytes(Int64(SetupPlatform.memoryBytes))) memory."
            )
            let recommendation = SetupPlatform.recommendedModel()
            log("RAM-aware RoachClaw recommendation: \(recommendation.model) (\(recommendation.tier)).")

            setPhase("Validating contained install lane", 12)
            for check in checks where check["required"].truthy && !check["available"].truthy {
                throw RuntimeError(check["notes"].jsString)
            }
            log(
                "Install volume has \(checks.first { $0["id"].stringValue == "disk-space" }?["version"].jsString ?? "unknown") free."
            )

            setPhase("Staging RoachNet", 24)
            let staging = Path.join(
                Path.dirname(plan.installPath), "\(Path.basename(plan.installPath)).staging-\(JS.randomHex(8))")
            stagingRoot = staging
            try Files.mkdirp(staging)
            for directory in ["app", "bin", "runtime"] { try Files.mkdirp(Path.join(staging, directory)) }
            log("Staging the install beside the target folder on the same volume.")

            setPhase("Preparing RoachClaw", 38)
            if plan.installRoachClaw {
                log(
                    "RoachClaw runs on the native RoachInference engine inside roachnet-runtime; no separate model runner is installed."
                )
                let models =
                    [plan.config["roachClawDefaultModel"].jsString]
                    + plan.config["roachClawExtraModels"].array.compactMap(\.stringValue)
                log("RoachNet downloads \(models.joined(separator: ", ")) when it first opens.")
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
            if !plan.installRoachClaw { completedConfig["roachClawExtraModels"] = .array([]) }
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
            let kind = Self.errorKind(error)
            if let stagingRoot {
                if environment["ROACHNET_SETUP_KEEP_STAGED_FAILURE"] == "1" {
                    log("Preserving the staged install for debugging.")
                } else {
                    Files.remove(stagingRoot)
                    log("Removed the staged install so this Mac can retry setup cleanly.")
                }
            }
            updateTask { task in
                task["status"] = "failed"
                task["currentStep"] = JSON(
                    kind == "failed"
                        ? "Setup failed. Fix the issue and run install again."
                        : "Setup stopped before installing. The message says what to do.")
                task["finishedAt"] = JSON(JS.isoNow())
                task["error"] = JSON(message)
                task["errorKind"] = JSON(kind)
            }
            log("Setup failed: \(message)")
        }
        runLock = nil
        synchronized {
            lastCompletedTask = activeTask
            activeTask = nil
        }
    }

    public static let exitSetupRunning: Int32 = 75
    public static let exitStopped: Int32 = 65

    static func errorKind(_ error: Error) -> String {
        if let failure = error as? SetupRunLock.Failure {
            if case .unusable = failure { return "lock-unavailable" }
            return "setup-running"
        }
        if error is RestoreProblem { return "stopped" }
        return "failed"
    }

    func sanitizeError(_ error: Error, _ plan: InstallPlan) -> String {
        if error is RestoreProblem || error is SetupRunLock.Failure { return redact("\(error)") }
        let raw = "\(error)"
        if JS.matches("ENOSPC|no space left on device", raw, caseInsensitive: true) {
            let required = requiredFreeBytes(installRoachClaw: plan.installRoachClaw)
            return
                "RoachNet ran out of disk space while staging the install. Free up space or choose another folder; this install expects about \(SetupPlatform.formatBytes(required)) free."
        }
        var message = raw
        for path in [plan.installPath, plan.storagePath, plan.appPath].sorted(by: { $0.count > $1.count }) {
            message = message.replacingOccurrences(of: path, with: "RoachNet root")
        }
        return redact(message)
    }

    func requiredFreeBytes(installRoachClaw: Bool) -> Int64 {
        if environment["ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST"] == "1",
            let override = environment["ROACHNET_SETUP_TEST_MIN_FREE_BYTES"].flatMap(Int64.init)
        {
            return override
        }
        return installRoachClaw ? SetupEngine.minimumFreeWithRoachClaw : SetupEngine.minimumFreeBase
    }

    public var isInstalling: Bool {
        synchronized { activeTask?["status"].stringValue == "running" }
    }

    enum RecoveryOutcome: Equatable {
        case noBackup
        case restored
        case keptBackups
        case restoreFailed(RestoreProblem)
    }

    enum RestoreProblem: Error, Equatable, CustomStringConvertible {
        case rootIsBrokenLink(root: String)
        case folderUnreadable(folder: String)
        case backupUnreadable(backup: String, unreadable: String)
        case backupIsBrokenLink(backup: String)
        case rootNotMovable(backup: String, reason: String)
        case backupNotMovable(backup: String, reason: String, kept: [String])
        case backupTaken(backup: String, kept: [String])

        static let again = "run Setup again (with Homebrew: brew reinstall --cask roachnet)"

        var description: String {
            let stopped = "Setup stopped without installing anything or deleting your files."
            switch self {
            case .rootIsBrokenLink(let root):
                return
                    "\(root) is a link to something Setup can't reach, such as a drive that isn't connected. \(stopped) Connect it, or remove the link, then \(Self.again)."
            case .folderUnreadable(let folder):
                return
                    "Setup can't read \(folder), the folder that holds the install, so it can't tell whether an earlier upgrade left your previous install there. \(stopped) Make that folder readable, then \(Self.again)."
            case .backupUnreadable(let backup, let unreadable):
                let what =
                    unreadable == backup ? "which Setup can't read" : "and Setup can't read \(unreadable) inside it"
                return
                    "An earlier upgrade left your previous install in \(backup), \(what). \(stopped) Make that folder readable, then \(Self.again). To install without it, move the backup somewhere else first."
            case .backupIsBrokenLink(let backup):
                return
                    "An earlier upgrade left your previous install in \(backup), a link to something Setup can't reach, such as a drive that isn't connected. \(stopped) Connect it, then \(Self.again). To install without it, move the link somewhere else first."
            case .rootNotMovable(let backup, let reason):
                return
                    "An earlier upgrade left your previous install in \(backup), but Setup couldn't move what is in the install folder now aside to put it back (\(reason)). \(stopped) Quit RoachNet and anything else using the install folder, make sure you can rename it, then \(Self.again)."
            case .backupNotMovable(let backup, let reason, let kept):
                return
                    "An earlier upgrade left your previous install in \(backup), which Setup couldn't put back (\(reason)). \(stopped)\(Self.keptNote(kept)) Make sure you can rename that backup, then \(Self.again). To install without it, move the backup somewhere else first."
            case .backupTaken(let backup, let kept):
                return
                    "Something else, most likely another RoachNet Setup, moved \(backup) while Setup was putting it back. \(stopped)\(Self.keptNote(kept)) Let the other Setup finish, then \(Self.again)."
            }
        }

        var logNote: String {
            switch self {
            case .rootIsBrokenLink(let root):
                return
                    "The install folder \(root) is a link to something Setup can't reach, so Setup left it, and any backups beside it, as they are."
            case .folderUnreadable(let folder):
                return
                    "Setup can't list \(folder), the folder that holds the install, so it left any backups there as they are."
            case .backupUnreadable(let backup, let unreadable):
                return
                    "An earlier upgrade left a backup at \(backup) that Setup can't read (\(unreadable)), so it was left as it is."
            case .backupIsBrokenLink(let backup):
                return
                    "An earlier upgrade left a backup at \(backup) that is a link to something Setup can't reach, so it was left as it is."
            case .rootNotMovable(let backup, let reason):
                return
                    "An earlier upgrade left a backup at \(backup) that could not be restored automatically: what is in the install folder now couldn't be moved aside (\(reason))."
            case .backupNotMovable(let backup, let reason, let kept):
                return
                    "An earlier upgrade left a backup at \(backup) that could not be restored automatically: \(reason).\(Self.keptNote(kept))"
            case .backupTaken(let backup, let kept):
                return
                    "An earlier upgrade left a backup at \(backup) that could not be restored automatically: something else moved it first, most likely another Setup.\(Self.keptNote(kept))"
            }
        }

        static func keptNote(_ kept: [String]) -> String {
            kept.isEmpty ? "" : " What Setup moved aside is kept in \(kept.joined(separator: " and "))."
        }
    }

    enum SetupSiblingKind {
        case staging
        case backup
    }

    @discardableResult
    func recoverInterruptedInstall(finalRoot: String, removeStaging: Bool = true) -> RecoveryOutcome {
        let parent = Path.dirname(finalRoot)
        let base = Path.basename(finalRoot)
        let rootEntry = Files.lstatInfo(finalRoot)
        let rootMissing = rootEntry == nil
        if let rootEntry, rootEntry.st_mode & S_IFMT == S_IFLNK, !Files.exists(finalRoot) {
            let problem = RestoreProblem.rootIsBrokenLink(root: finalRoot)
            log(problem.logNote)
            return .restoreFailed(problem)
        }
        let onlySetupFiles = !rootMissing && holdsOnlySetupFiles(finalRoot)
        let ignoringCase = SetupPlatform.namesIgnoreCase(in: parent)
        var notes: [String] = []
        defer { for note in notes { log(note) } }
        guard let siblings = Files.entriesIfReadable(parent) else {
            guard rootMissing || onlySetupFiles else {
                notes.append(RestoreProblem.folderUnreadable(folder: parent).logNote)
                return .keptBackups
            }
            let problem = RestoreProblem.folderUnreadable(folder: parent)
            notes.append(problem.logNote)
            return .restoreFailed(problem)
        }
        if removeStaging {
            for entry in siblings
            where entry.isDirectory
                && Self.isSetupSibling(entry.name, base: base, kind: .staging, ignoringCase: ignoringCase)
            {
                Files.remove(Path.join(parent, entry.name))
                notes.append("Removed an unfinished staged install left by an earlier run.")
            }
        }
        let backups =
            siblings
            .filter { entry in
                guard Self.isSetupSibling(entry.name, base: base, kind: .backup, ignoringCase: ignoringCase) else {
                    return false
                }
                let path = Path.join(parent, entry.name)
                return entry.isDirectory || (entry.isSymbolicLink && (Files.isDirectory(path) || !Files.exists(path)))
            }
            .map(\.name)
            .sorted { (Self.backupStamp($0), $0) > (Self.backupStamp($1), $1) }
        guard let newest = backups.first else { return .noBackup }
        let several = backups.count > 1
        let described = several ? "\(backups.count) backups" : "a backup"
        guard rootMissing || onlySetupFiles else {
            notes.append(
                "An earlier upgrade left \(described) beside the install (newest: \(newest)). \(several ? "They are" : "It is") kept in case \(several ? "they hold" : "it holds") storage you need."
            )
            return .keptBackups
        }
        var chosen: String?
        search: for name in backups {
            let folder = Path.join(parent, name)
            if !Files.exists(folder) {
                let problem = RestoreProblem.backupIsBrokenLink(backup: folder)
                notes.append(problem.logNote)
                return .restoreFailed(problem)
            }
            switch backupShape(folder) {
            case .unreadable(let unreadable):
                let problem = RestoreProblem.backupUnreadable(backup: folder, unreadable: unreadable)
                notes.append(problem.logNote)
                return .restoreFailed(problem)
            case .more:
                chosen = name
                break search
            case .onlySetupFiles:
                continue
            }
        }
        guard let chosen else {
            notes.append(
                "An earlier upgrade left \(described) beside the install (newest: \(newest)) holding only Setup's own files, so there was nothing to put back. \(several ? "They are" : "It is") kept."
            )
            return .keptBackups
        }
        let backup = Path.join(parent, chosen)
        do {
            var leftovers: [String] = []
            if rootMissing {
                do {
                    try moveIntoPlace(backup, finalRoot)
                } catch {
                    throw Files.lstatInfo(backup) == nil
                        ? RestoreProblem.backupTaken(backup: backup, kept: [])
                        : RestoreProblem.backupNotMovable(backup: backup, reason: "\(error)", kept: [])
                }
            } else {
                leftovers = try restoreBackup(backup, over: finalRoot)
            }
            notes.append("Restored the previous install that an interrupted upgrade had moved aside (\(chosen)).")
            let others = backups.count - 1
            if others > 0 {
                notes.append(
                    "\(others == 1 ? "1 other backup is" : "\(others) other backups are") kept beside the install in case \(others == 1 ? "it holds" : "they hold") storage you need."
                )
            }
            notes += leftovers
            return .restored
        } catch {
            let problem = error as? RestoreProblem ?? .backupNotMovable(backup: backup, reason: "\(error)", kept: [])
            notes.append(problem.logNote)
            return .restoreFailed(problem)
        }
    }

    func restoreBackup(_ backup: String, over root: String) throws -> [String] {
        let stamp = Int(JS.nowMs())
        let aside = "\(root).setup-files-\(stamp)"
        do {
            try moveIntoPlace(root, aside)
        } catch {
            throw RestoreProblem.rootNotMovable(backup: backup, reason: "\(error)")
        }
        do {
            try moveIntoPlace(backup, root)
        } catch {
            guard Files.lstatInfo(backup) != nil else {
                throw RestoreProblem.backupTaken(backup: backup, kept: [aside])
            }
            var kept: [String] = []
            if Files.lstatInfo(root) != nil {
                let partial = "\(root).partial-restore-\(stamp)"
                if (try? SetupPlatform.moveItem(root, partial)) != nil { kept.append(partial) }
            }
            var setupFilesBack = false
            if Files.lstatInfo(root) == nil { setupFilesBack = (try? SetupPlatform.moveItem(aside, root)) != nil }
            if !setupFilesBack { kept.append(aside) }
            throw RestoreProblem.backupNotMovable(backup: backup, reason: "\(error)", kept: kept)
        }
        var notes: [String] = []
        let caskApp = Path.join(aside, "setup", "RoachNet Setup.app")
        if Files.lstatInfo(caskApp) != nil {
            let restoredApp = Path.join(root, "setup", "RoachNet Setup.app")
            let olderApp = Path.join(aside, "RoachNet Setup.app.from-backup")
            do {
                if Files.lstatInfo(restoredApp) != nil { try SetupPlatform.moveItem(restoredApp, olderApp) }
                try SetupPlatform.moveItem(caskApp, restoredApp)
                Files.remove(olderApp)
            } catch {
                if Files.lstatInfo(restoredApp) == nil, Files.lstatInfo(olderApp) != nil {
                    try? SetupPlatform.moveItem(olderApp, restoredApp)
                }
                notes.append("The newer Setup app the Homebrew cask had put back stays in \(aside): \(error)")
            }
        }
        let strayLogs = Path.join(aside, "storage", "logs")
        for entry in Files.entries(strayLogs) where !entry.isDirectory {
            do {
                try Files.mkdirp(Path.join(root, "storage", "logs"))
                try SetupPlatform.moveItem(
                    Path.join(strayLogs, entry.name),
                    Path.join(root, "storage", "logs", "\(entry.name).before-recovery-\(stamp)"))
            } catch {
                notes.append("An earlier Setup's log \(entry.name) stays in \(aside): \(error)")
            }
        }
        if holdsNothing(aside) {
            Files.remove(aside)
        } else if notes.isEmpty {
            notes.append("Setup's other files from before the restore are kept in \(aside).")
        }
        return notes
    }

    func holdsOnlySetupFiles(_ root: String) -> Bool {
        guard Files.isDirectory(root), manifestText(root) == nil, !Files.exists(canonicalAppPath(root)) else {
            return false
        }
        return holdsOnlySetupShape(root) == true
    }

    enum FolderShape: Equatable {
        case onlySetupFiles
        case more
        case unreadable(String)
    }

    func setupShape(_ folder: String) -> FolderShape {
        guard let entries = Files.entriesIfReadable(folder) else { return .unreadable(folder) }
        var unreadable: String?
        for entry in entries where entry.name != ".DS_Store" {
            switch entry.name {
            case "setup":
                if !entry.isDirectory { return .more }
            case "storage":
                if !entry.isDirectory { return .more }
                let storage = Path.join(folder, "storage")
                guard let children = Files.entriesIfReadable(storage) else {
                    unreadable = unreadable ?? storage
                    continue
                }
                for child in children where child.name != ".DS_Store" {
                    if child.name != "logs" || !child.isDirectory { return .more }
                    let logs = Path.join(storage, "logs")
                    guard let files = Files.entriesIfReadable(logs) else {
                        unreadable = unreadable ?? logs
                        continue
                    }
                    if files.contains(where: \.isDirectory) { return .more }
                }
            default:
                return .more
            }
        }
        if let unreadable { return .unreadable(unreadable) }
        return .onlySetupFiles
    }

    func backupShape(_ folder: String) -> FolderShape {
        if manifestText(folder) != nil || Files.exists(canonicalAppPath(folder)) { return .more }
        return setupShape(folder)
    }

    func holdsMoreThanSetupFiles(_ folder: String) -> Bool? {
        switch backupShape(folder) {
        case .more: return true
        case .onlySetupFiles: return false
        case .unreadable: return nil
        }
    }

    func holdsOnlySetupShape(_ folder: String) -> Bool? {
        switch setupShape(folder) {
        case .onlySetupFiles: return true
        case .more: return false
        case .unreadable: return nil
        }
    }

    func holdsNothing(_ folder: String) -> Bool {
        guard let entries = Files.entriesIfReadable(folder) else { return false }
        return entries.allSatisfy { entry in
            entry.name == ".DS_Store" || (entry.isDirectory && holdsNothing(Path.join(folder, entry.name)))
        }
    }

    func manifestText(_ root: String) -> String? {
        Files.readText(Path.join(root, SetupEngine.installManifestName))
    }

    static func isSetupSibling(_ name: String, base: String, kind: SetupSiblingKind, ignoringCase: Bool) -> Bool {
        let scalars = name.unicodeScalars
        guard let dash = scalars.lastIndex(of: "-") else { return false }
        let suffix = String(String.UnicodeScalarView(scalars[scalars.index(after: dash)...]))
        let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
        let lowerHex: ClosedRange<Unicode.Scalar> = "a"..."f"
        let marker: String
        switch kind {
        case .staging:
            guard suffix.unicodeScalars.count == 8,
                suffix.unicodeScalars.allSatisfy({ digits.contains($0) || lowerHex.contains($0) })
            else { return false }
            marker = ".staging-"
        case .backup:
            guard suffix.unicodeScalars.count == 13,
                suffix.unicodeScalars.allSatisfy({ digits.contains($0) })
            else { return false }
            marker = ".backup-"
        }
        let expected = base + marker + suffix
        return Path.hasNamePrefix(name, expected, ignoringCase: ignoringCase)
            && Path.hasNamePrefix(expected, name, ignoringCase: ignoringCase)
    }

    static func backupStamp(_ name: String) -> Int64 {
        let scalars = name.unicodeScalars
        guard let dash = scalars.lastIndex(of: "-") else { return -1 }
        return Int64(String(String.UnicodeScalarView(scalars[scalars.index(after: dash)...]))) ?? -1
    }

    func provisionLocalAlias() throws {
        let explicitHostsFile =
            environment["ROACHNET_HOSTS_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            log(
                outcome.changed
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

    func resolveAppSource(scratch: String) throws -> String {
        var candidates: [String] = []
        if let explicit = environment["ROACHNET_SETUP_DESKTOP_APP"], !explicit.isEmpty {
            candidates.append(Path.resolve(explicit))
        }
        if let assets = installerAssetsPath {
            candidates.append(Path.join(assets, "RoachNet.app"))
            candidates.append(Path.join(assets, "RoachNet-\(version)-mac-arm64.zip"))
            for entry in Files.entries(assets)
            where entry.name.hasPrefix("RoachNet-") && entry.name.hasSuffix(".zip") && entry.name.contains("mac-arm64")
            {
                candidates.append(Path.join(assets, entry.name))
            }
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
        throw RuntimeError(
            "RoachNet Setup could not find the RoachNet app payload. Download a fresh copy of RoachNet Setup and try again."
        )
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
                throw RuntimeError(
                    "The installed RoachNet runtime exited during verification (status \(process.terminationStatus)).")
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
        for pattern in [
            "/RoachNet.app/Contents/MacOS/RoachNetApp", "\(plan.appPath)/Contents/Helpers/\(appHelperName)",
            Path.join(plan.installPath, "scripts", "run-roachnet-native-api.mjs"),
            Path.join(plan.installPath, "scripts", "roachnet-companion-server.mjs"),
        ] {
            if SetupPlatform.terminateProcesses(
                matching: JS.replace("[\\\\^$.*+?()\\[\\]{}|]", in: pattern, with: "\\\\$0"))
            {
                closed += 1
            }
        }
        if closed > 0 { log("Closed running RoachNet processes before replacing the installed copy.") }
    }

    func isInside(_ candidate: String, _ root: String) -> Bool {
        let relative = Path.relative(from: root, to: candidate)
        return !relative.isEmpty && !relative.hasPrefix("..") && !Path.isAbsolute(relative)
    }

    func finalizeInstallRoot(staging: String, finalRoot: String, storagePath: String) throws {
        let backup =
            Files.exists(finalRoot)
            ? Path.join(Path.dirname(finalRoot), "\(Path.basename(finalRoot)).backup-\(Int(JS.nowMs()))") : nil
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

    public func launch(_ payload: JSON) throws -> JSON {
        let config = defaultConfig(payload)
        let installPath = normalizeInputPath(payload["installPath"] || config["installPath"])
        let appPath = normalizeInputPath(
            payload["installedAppPath"] || config["installedAppPath"] || JSON(canonicalAppPath(installPath)))
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
                return .json(
                    400, ["ok": false, "error": "RoachNet runs natively and does not use a container runtime."])
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

    public func serve() throws -> LoopbackHTTPServer {
        let requestedPort = UInt16(environment["ROACHNET_SETUP_PORT"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let server = LoopbackHTTPServer(host: "127.0.0.1", port: requestedPort, maxBodyBytes: 1024 * 1024) {
            [self] request in
            handle(&request)
        }
        try server.start()
        let url = "http://127.0.0.1:\(server.port)"
        if let ready = environment["ROACHNET_SETUP_READY_FILE"], !ready.isEmpty {
            let readyPayload: JSON = [
                "url": JSON(url), "pid": JSON(Int(getpid())), "startedAt": JSON(JS.isoNow()), "runtime": "native-swift",
            ]
            try Files.write(readyPayload.prettySerialized() + "\n", to: ready)
        }
        RuntimeLog.write("setup service listening on \(url)")
        return server
    }
}

final class SetupRunLock {
    enum Blocker: Equatable {
        case link, folder, notAFile
        case anotherUser
        case unopenable(String)
    }

    enum Failure: Error, CustomStringConvertible {
        case busy
        case blocked(path: String, blocker: Blocker)
        case unusable(path: String, reason: String)

        var description: String {
            switch self {
            case .busy:
                return "Another RoachNet Setup is running. Let it finish, then run Setup again."
            case .blocked(let path, .link):
                return
                    "Setup can't use its lock file \(path): a link is in its place, and Setup never makes one there. Nothing was changed. Remove that link, then run Setup again."
            case .blocked(let path, .folder):
                return
                    "Setup can't use its lock file \(path): a folder is in its place, and Setup never makes one there. Nothing was changed. Move that folder out of the way, then run Setup again."
            case .blocked(let path, .notAFile):
                return
                    "Setup can't use its lock file \(path): something that isn't a file is in its place, and Setup never makes one there. Nothing was changed. Move it out of the way, then run Setup again."
            case .blocked(let path, .anotherUser):
                return
                    "Setup can't use its lock file \(path): it belongs to another user, for example from a Setup run with sudo. Nothing was changed. If no Setup is running, have an administrator remove that file, then run Setup again."
            case .blocked(let path, .unopenable(let reason)):
                return
                    "Setup can't open its lock file \(path) (\(reason)), so it can't tell whether another Setup is running. Nothing was changed. If none is, remove that file, then run Setup again."
            case .unusable(let path, let reason):
                return
                    "Setup can't use its lock file \(path) (\(reason)), so it can't make sure no other Setup is running. Nothing was changed. Check that this folder exists, that you can write to it, and that it's on a disk with file locks, then run Setup again."
            }
        }
    }

    typealias LockCall = (Int32, Int32) -> Int32

    private let fd: Int32

    init(path: String, lockCall: LockCall = { flock($0, $1) }, owner: uid_t = geteuid()) throws {
        do {
            try Files.mkdirp(Path.dirname(path))
        } catch {
            throw Failure.unusable(path: path, reason: SetupRunLock.reason(error))
        }
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var fd = open(path, flags, mode_t(0o600))
        if fd < 0 && errno == EINTR { fd = open(path, flags, mode_t(0o600)) }
        guard fd >= 0 else {
            let code = errno
            let reason = String(cString: strerror(code))
            if let there = Files.lstatInfo(path), code == EACCES || code == EPERM || code == ELOOP || code == EISDIR {
                let type = mode_t(truncatingIfNeeded: there.st_mode) & S_IFMT
                let blocker: Blocker =
                    type == S_IFLNK
                    ? .link
                    : type == S_IFDIR
                        ? .folder
                        : type != S_IFREG
                            ? .notAFile
                            : there.st_uid != owner
                                ? .anotherUser
                                : .unopenable(reason)
                throw Failure.blocked(path: path, blocker: blocker)
            }
            throw Failure.unusable(path: path, reason: reason)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure.unusable(path: path, reason: reason)
        }
        guard mode_t(truncatingIfNeeded: info.st_mode) & S_IFMT == S_IFREG else {
            close(fd)
            throw Failure.blocked(path: path, blocker: .notAFile)
        }
        guard info.st_uid == owner else {
            close(fd)
            throw Failure.blocked(path: path, blocker: .anotherUser)
        }
        var locked = lockCall(fd, LOCK_EX | LOCK_NB)
        if locked != 0 && errno == EINTR { locked = lockCall(fd, LOCK_EX | LOCK_NB) }
        guard locked == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK
                ? Failure.busy : Failure.unusable(path: path, reason: String(cString: strerror(code)))
        }
        self.fd = fd
    }

    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return error.localizedDescription
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
