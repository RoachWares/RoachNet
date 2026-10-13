import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension NativeRuntime {
    // MARK: Providers

    func urlJoin(_ path: String, _ base: String) -> String {
        WebURL(path, base: WebURL(base))?.description ?? base + path
    }

    func isReachable(_ url: String) -> Bool { (try? runtimeReachabilityCache.get(url)) ?? false }

    /// What answers RoachNet's model requests, in words for status lines.
    var modelServerName: String { modelServerIsOllama ? "Ollama" : "The RoachInference model server" }

    /// True while a person's own Ollama answers RoachNet's model requests
    /// (ROACHNET_INFERENCE_ENGINE=ollama, and that Ollama is running).
    var modelServerIsOllama: Bool { personsOllamaInUse.value }

    /// Makes the local model lane reachable. RoachInference, RoachNet's own
    /// engine, is the default. With ROACHNET_INFERENCE_ENGINE=ollama, an
    /// Ollama the person runs is used where it already listens
    /// (`personsOllamaURL`), and RoachInference answers whenever it isn't
    /// running. RoachNet never starts or stops an Ollama and never listens on
    /// Ollama's port, so a person's Ollama and RoachNet run side by side.
    @discardableResult
    func ensureOllama() -> Bool {
        if !usesNativeEngine {
            let ollama = personsOllamaURL
            let version = urlJoin("/api/version", ollama)
            if isReachable(version), !answersAsRoachInference(version) {
                personsOllamaInUse.value = true
                useModelServer(at: ollama)
                return true
            }
            if !personsOllamaMissingLogged.value {
                personsOllamaMissingLogged.value = true
                log("ROACHNET_INFERENCE_ENGINE=ollama, but no Ollama answers at \(safeServiceUrl(JSON(ollama))); RoachInference answers until one does. "
                    + "RoachNet doesn't start Ollama itself: start it, or set ROACHNET_OLLAMA_URL to where it listens.")
            }
        }
        personsOllamaInUse.value = false
        return ensureNativeModelServer()
    }

    /// Where a person's own Ollama listens: `ROACHNET_OLLAMA_URL` when set;
    /// otherwise `OLLAMA_BASE_URL` when somebody pointed it somewhere other
    /// than RoachNet's own model address; otherwise Ollama's default.
    var personsOllamaURL: String {
        if let explicit = config.env("ROACHNET_OLLAMA_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if !Self.isRoachNetOwnModelURL(config.ollamaBaseUrl) { return config.ollamaBaseUrl }
        return "http://127.0.0.1:\(Self.ollamaPort)"
    }

    /// Ollama's default port. RoachNet never listens there, so a person's
    /// Ollama can always start.
    static let ollamaPort = "11434"

    /// RoachNet's own model port. The app sets `OLLAMA_BASE_URL` to
    /// `http://127.0.0.1:36434`, which is also the runtime's default.
    static let roachNetModelPort = "36434"

    /// Where RoachInference listens: the configured model address, except
    /// that RoachNet never takes Ollama's port. An address on 11434, or with
    /// no port, means RoachNet's own port, and so does
    /// ROACHNET_INFERENCE_ENGINE=ollama, where the configured address may be
    /// the person's Ollama.
    var roachInferenceURL: String {
        let own = "http://127.0.0.1:\(Self.roachNetModelPort)"
        guard usesNativeEngine, let parsed = WebURL(config.ollamaBaseUrl),
              !parsed.port.isEmpty, parsed.port != Self.ollamaPort else { return own }
        return config.ollamaBaseUrl
    }

    /// Whether `url` is RoachNet's own model address (loopback, port 36434)
    /// rather than one somebody set on purpose.
    static func isRoachNetOwnModelURL(_ url: String) -> Bool {
        guard let parsed = WebURL(url), parsed.port == roachNetModelPort else { return false }
        return (try? RuntimeServer.normalizeLoopbackHost(parsed.hostname)) != nil
    }

    /// Whether `OLLAMA_BASE_URL` is RoachNet's own model address.
    var usesRoachNetModelAddress: Bool { Self.isRoachNetOwnModelURL(config.ollamaBaseUrl) }

    /// Points RoachNet's model traffic at `address`.
    func useModelServer(at address: String) {
        guard modelServerAddress.value != address else { return }
        modelServerAddress.value = address
        runtimeReachabilityCache.invalidate(urlJoin("/api/version", address))
        installedModelsCache.invalidate(address)
    }

    /// Makes sure RoachInference answers at `roachInferenceURL` and, when
    /// `route` is true, points RoachNet's model traffic at it:
    /// - another runtime's RoachInference there is shared;
    /// - an address somebody chose with `OLLAMA_BASE_URL` is used as
    ///   configured, whatever answers there;
    /// - on RoachNet's own address (loopback port 36434), any other program
    ///   keeps its port and is never stopped from here. That is usually a 1.0.x
    ///   `ollama serve` that outlived its app after an upgrade. RoachNet's model
    ///   traffic doesn't quietly go to it: RoachInference takes a free loopback
    ///   port and `modelServerBaseUrl` points there.
    @discardableResult
    func ensureNativeModelServer(route: Bool = true) -> Bool {
        if let address = roachInferenceAddress.value {
            if route { useModelServer(at: address) }
            return true
        }
        let target = roachInferenceURL
        let version = urlJoin("/api/version", target)
        guard isReachable(version) else { return startNativeModelServer(at: target, route: route) }
        if answersAsRoachInference(version) || !Self.isRoachNetOwnModelURL(target) {
            if route { useModelServer(at: target) }
            return true
        }
        return startNativeModelServer(at: target, onFreePort: true, route: route)
    }

    /// RoachInference's `/api/version` names it (`roachnet-native-…`); Ollama's is a bare version.
    func answersAsRoachInference(_ versionURL: String) -> Bool {
        (try? roachInferenceIdentityCache.get(versionURL)) ?? false
    }

    /// Serves the native engine at `target` (loopback only, never Ollama's
    /// port), or on a free loopback port when another program holds
    /// RoachNet's own port.
    @discardableResult
    func startNativeModelServer(at target: String, onFreePort: Bool = false, route: Bool = true) -> Bool {
        withState {
            if let address = roachInferenceAddress.value {
                if route { useModelServer(at: address) }
                return true
            }
            guard let parsed = WebURL(target),
                  let host = try? RuntimeServer.normalizeLoopbackHost(parsed.hostname),
                  let port = UInt16(parsed.port), parsed.port != Self.ollamaPort else {
                log("native model server not started: \(safeServiceUrl(JSON(target))) must be a loopback address with a port other than Ollama's \(Self.ollamaPort)")
                return false
            }
            let server = nativeModelServer ?? NativeModelServer(store: nativeModelStore)
            server.tracer = tracer
            server.subscriptions = subscriptionModels
            let bindHost = host == "localhost" ? "127.0.0.1" : host
            do {
                do {
                    try server.start(host: bindHost, port: onFreePort ? 0 : port)
                } catch where !onFreePort && Self.isRoachNetOwnModelURL(target) {
                    // Something that doesn't answer HTTP holds RoachNet's own port.
                    log("RoachInference couldn't listen on \(target) (\(error)); using a free loopback port")
                    try server.start(host: bindHost, port: 0)
                }
                guard let bound = server.server?.port else { return false }
                let address = bound == port ? target : "http://\(bindHost.contains(":") ? "[\(bindHost)]" : bindHost):\(bound)"
                if address != target {
                    log("another program holds \(target), so RoachInference serves \(address). "
                        + "Quit that program and restart RoachNet to use the usual address.")
                }
                roachInferenceAddress.value = address
                nativeModelServer = server
                #if canImport(CryptoKit) && canImport(Metal)
                cluster.server = server
                server.cluster = cluster
                cluster.start()
                #endif
                if route { useModelServer(at: address) }
                runtimeReachabilityCache.invalidate(urlJoin("/api/version", address))
                installedModelsCache.invalidate(address)
                return true
            } catch {
                log("native model server could not listen on \(onFreePort ? "a free port on \(bindHost)" : target): \(error)")
                return false
            }
        }
    }

    func providerStatus(_ provider: String, _ baseUrl: String) -> JSON {
        let endpoint = provider == "ollama" ? "/api/version" : "/health"
        let available = isReachable(urlJoin(endpoint, baseUrl))
        return [
            "provider": JSON(provider),
            "available": JSON(available),
            "source": JSON(available ? "native-api" : "configured"),
            "baseUrl": JSON(baseUrl),
            "error": available ? nil : JSON("\(provider) is not reachable yet."),
        ]
    }

    func installedModels() -> [JSON] {
        ensureOllama()
        return (try? installedModelsCache.get(modelServerBaseUrl)) ?? []
    }

    // MARK: System info

    static func cpuBrand() -> String {
        #if canImport(Darwin)
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                let value = String(cString: buffer)
                if !value.isEmpty { return value }
            }
        }
        return "Apple Silicon"
        #else
        if let info = Files.readText("/proc/cpuinfo") {
            for line in info.split(separator: "\n") where line.lowercased().hasPrefix("model name") {
                if let colon = line.firstIndex(of: ":") { return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
        }
        return "Apple Silicon"
        #endif
    }

    static func freeMemory() -> UInt64 {
        #if canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(stats.free_count) * UInt64(vm_kernel_page_size)
        #else
        if let info = Files.readText("/proc/meminfo") {
            for line in info.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
                let digits = line.filter { $0.isNumber }
                return (UInt64(digits) ?? 0) * 1024
            }
        }
        return 0
        #endif
    }

    static func kernel() -> (type: String, release: String) {
        var name = utsname()
        uname(&name)
        let sysname = withUnsafePointer(to: &name.sysname) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        let release = withUnsafePointer(to: &name.release) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return (sysname, release)
    }

    func systemInfo() -> JSON {
        let cores = ProcessInfo.processInfo.processorCount
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let isAppleSilicon = Host.isAppleSilicon
        let memoryGB = Double(totalMemory) / 1024 / 1024 / 1024
        let memoryTier = memoryGB >= 32 ? "creator" : memoryGB >= 16 ? "balanced" : "compact"
        let recommendedModelClass = memoryGB >= 32 ? "14b" : memoryGB >= 16 ? "7b" : "1.5b"
        let kernel = NativeRuntime.kernel()
        return [
            "cpu": [
                "manufacturer": isAppleSilicon ? "Apple" : nil,
                "brand": JSON(NativeRuntime.cpuBrand()),
                "physicalCores": JSON(max(1, JS.round(Double(cores) / 2))),
                "cores": JSON(cores),
            ],
            "mem": [
                "total": JSON(Double(totalMemory)),
                "available": JSON(Double(NativeRuntime.freeMemory())),
                "swapused": nil,
            ],
            "os": [
                "hostname": JSON(Host.hostname),
                "arch": JSON(Host.arch),
                "distro": JSON("\(kernel.type) \(kernel.release)"),
            ],
            "hardwareProfile": [
                "platformLabel": JSON(isAppleSilicon ? "Apple Silicon Mac" : "\(Host.platform) \(Host.arch)"),
                "chipFamily": JSON(isAppleSilicon ? "apple_silicon" : Host.arch),
                "isAppleSilicon": JSON(isAppleSilicon),
                "memoryTier": JSON(memoryTier),
                "recommendedRuntime": "native_local",
                "recommendedModelClass": JSON(recommendedModelClass),
                "notes": ["Native API bridge is running without the Electron/WebUI admin runtime."],
                "warnings": isAppleSilicon ? [] : ["This release target is Apple Silicon macOS."],
            ],
        ]
    }

    // MARK: RoachClaw status

    func roachClawStatus() -> JSON {
        ensureOllama()
        let group = DispatchGroup()
        let ollamaBox = LockedBox<JSON>(.null)
        let openclawBox = LockedBox<JSON>(.null)
        let modelsBox = LockedBox<[JSON]>([])
        group.enter()
        DispatchQueue.global().async { ollamaBox.value = self.providerStatus("ollama", self.modelServerBaseUrl); group.leave() }
        group.enter()
        DispatchQueue.global().async { openclawBox.value = self.providerStatus("openclaw", self.config.openClawBaseUrl); group.leave() }
        group.enter()
        DispatchQueue.global().async { modelsBox.value = self.installedModels(); group.leave() }
        group.wait()
        let ollama = ollamaBox.value
        let openclaw = openclawBox.value
        let models = modelsBox.value

        let modelNames = models.compactMap { $0["name"].stringValue }
        let workspacePath = config.env("OPENCLAW_WORKSPACE_PATH").flatMap { $0.isEmpty ? nil : $0 } ?? Path.join(storageRoot, "RoachClaw")
        let resolvedDefaultModel = modelNames.contains(defaultModel) ? defaultModel : (modelNames.first ?? defaultModel)
        let agent = RoachClawAgent.status(storageRoot: storageRoot, defaultModel: defaultModel, resolvedDefaultModel: resolvedDefaultModel)
        return [
            "label": "RoachClaw Native",
            "ollama": ollama,
            "openclaw": openclaw,
            "agent": agent,
            "operations": roachClawOperationsState(ollama: ollama, openclaw: openclaw, models: models, modelNames: modelNames, agent: agent),
            "cliStatus": [
                "openclawAvailable": openclaw["available"],
                "clawhubAvailable": false,
                "workspacePath": JSON(workspacePath),
                "runner": "native-api",
            ],
            "workspacePath": JSON(workspacePath),
            "defaultModel": JSON(defaultModel),
            "resolvedDefaultModel": JSON(resolvedDefaultModel),
            "preferredMode": "local",
            "ready": ollama["available"],
            "installedModels": jsonStrings(modelNames),
            "modelRecords": .array(models),
            "preferredModels": ["qwen2.5-coder:1.5b", "qwen2.5-coder:7b", "qwen2.5-coder:14b"],
            "configFilePath": nil,
            "portableProfile": nil,
            "playbook": roachClawPlaybook(ollama: ollama, openclaw: openclaw, modelNames: modelNames),
        ]
    }

    // MARK: Shell surfaces

    private static let closedTaskStatuses: Set<String> = ["done", "cancelled", "archived"]
    private static let closedDraftStatuses: Set<String> = ["archived", "published", "discarded"]

    func lowerStatus(_ value: JSON) -> String { (value["status"] || "").jsString.lowercased() }

    func roachClawShellSurfaces(tasks: JSON, calendar: JSON, reports: JSON, memories: JSON, skills: JSON, editorDrafts: JSON,
                                searchCache: JSON, gallery: JSON, webhooks: JSON, agentRuns: JSON, contextCompactions: JSON,
                                toolIndex: JSON, events: JSON, mail: JSON, presets: JSON, backups: JSON) -> JSON {
        let taskRecords = tasks["tasks"].array
        let calendarRecords = calendar["events"].array
        let reportRecords = reports["reports"].array
        let memoryRecords = memories["memories"].array
        let skillRecords = skills["skills"].array
        let draftRecords = editorDrafts["drafts"].array
        let searchRecords = searchCache["entries"].array
        let galleryRecords = gallery["assets"].array
        let webhookRecords = webhooks["webhooks"].array
        let runRecords = agentRuns["runs"].array
        let compactionRecords = contextCompactions["compactions"].array
        let toolRecords = toolIndex["tools"].array
        let eventRecords = events["events"].array
        let mailDrafts = mail["drafts"].array
        let presetRecords = presets["templates"].array
        let backupRecords = backups["snapshots"].array

        let openTasks = taskRecords.filter { !NativeRuntime.closedTaskStatuses.contains(lowerStatus($0)) }.count
        let activeRuns = runRecords.filter { ["running", "queued"].contains(lowerStatus($0)) }.count
        let stalledRuns = runRecords.filter { ["stalled", "blocked", "error", "failed"].contains(lowerStatus($0)) }.count
        let activeTools = toolRecords.filter { $0["enabled"].truthy }.count
        let armedHooks = webhookRecords.filter { $0["isActive"].truthy }.count
        let armedEvents = eventRecords.filter { $0["enabled"].truthy }.count
        let contextCount = memoryRecords.count + compactionRecords.count + searchRecords.count + draftRecords.count
        let commandCount = activeTools + skillRecords.count + presetRecords.count + armedHooks
        let vaultCount = galleryRecords.count + searchRecords.count + draftRecords.count + reportRecords.count
        let handoffCount = openTasks + calendarRecords.count + mailDrafts.count + armedEvents
        let openDrafts = draftRecords.filter { !NativeRuntime.closedDraftStatuses.contains(lowerStatus($0)) }.count

        return [
            "commandDeck": [
                "status": JSON(commandCount > 0 ? "indexed" : "ready"),
                "count": JSON(commandCount),
                "active": JSON(activeTools),
                "priority": JSON(activeTools > 0 || commandCount > 0 ? "fast-launch" : "prime"),
                "route": "roachnet://command",
                "hotkey": "Ctrl-Cmd-R",
                "summaryItems": [JSON("\(activeTools) armed tools"), JSON("\(skillRecords.count) skills"), JSON("\(presetRecords.count) presets"), JSON("\(armedHooks) hooks")],
                "detail": "Raycast-style command surface backed by local tool cards, skills, presets, and scoped hooks.",
                "actions": ["Search commands", "Preview context", "Run with approval", "Pin useful actions"],
            ],
            "contextRail": [
                "status": JSON(contextCount > 0 ? "warm" : "empty"),
                "count": JSON(contextCount),
                "open": JSON(openDrafts),
                "priority": JSON(contextCount > 0 ? "attached" : "empty"),
                "route": "roachnet://roachclaw/context",
                "hotkey": "Cmd-Shift-C",
                "summaryItems": [JSON("\(memoryRecords.count) memories"), JSON("\(compactionRecords.count) compactions"), JSON("\(searchRecords.count) crumbs"), JSON("\(draftRecords.count) drafts")],
                "detail": "Cursor-style side rail for memories, compactions, search crumbs, and editable drafts.",
                "actions": ["Show visible context", "Compact thread", "Attach vault crumb", "Save working note"],
            ],
            "vaultNavigator": [
                "status": JSON(vaultCount > 0 ? "indexed" : "empty"),
                "count": JSON(vaultCount),
                "active": JSON(galleryRecords.count),
                "priority": JSON(vaultCount > 0 ? "browse" : "feed"),
                "route": "roachnet://vault",
                "hotkey": "Cmd-Shift-V",
                "summaryItems": [JSON("\(galleryRecords.count) assets"), JSON("\(reportRecords.count) reports"), JSON("\(searchRecords.count) source crumbs"), JSON("\(draftRecords.count) drafts")],
                "detail": "Finder-like local navigator for vault assets, report outputs, source crumbs, and staged drafts.",
                "actions": ["Browse vault", "Preview asset", "Reveal path", "Drop files into shelf"],
            ],
            "agentMonitor": [
                "status": JSON(activeRuns > 0 ? "running" : (stalledRuns > 0 ? "needs-review" : "idle")),
                "count": JSON(runRecords.count),
                "active": JSON(activeRuns),
                "stalled": JSON(stalledRuns),
                "priority": JSON(stalledRuns > 0 ? "review" : (activeRuns > 0 ? "watch" : "idle")),
                "route": "roachnet://roachclaw/runs",
                "hotkey": "Cmd-Shift-M",
                "summaryItems": [JSON("\(activeRuns) running"), JSON("\(stalledRuns) stalled"), JSON("\(eventRecords.count) counters"), JSON("\(toolRecords.count) tools")],
                "detail": "Activity Monitor-style view of autonomous RoachClaw runs, replay crumbs, and local event pressure.",
                "actions": ["Inspect run", "Stop noisy work", "Replay events", "Collect evidence"],
            ],
            "orchestrationDashboard": [
                "status": JSON(activeRuns > 0 || handoffCount > 0 ? "coordinating" : "ready"),
                "count": JSON(runRecords.count + reportRecords.count + backupRecords.count),
                "active": JSON(activeRuns),
                "open": JSON(handoffCount),
                "priority": JSON(activeRuns > 0 || handoffCount > 0 ? "coordinate" : "ready"),
                "route": "roachnet://roachclaw/orchestration",
                "hotkey": "Cmd-Shift-O",
                "summaryItems": [JSON("\(runRecords.count) runs"), JSON("\(openTasks) open tasks"), JSON("\(calendarRecords.count) calendar"), JSON("\(backupRecords.count) snapshots")],
                "detail": "Monet-style dashboard for local agent roles, context budgets, handoffs, and outcome ledgers.",
                "actions": ["Assign roles", "Set context budgets", "Track handoffs", "Publish outcome"],
            ],
        ]
    }

    // MARK: Service health

    func serviceHealthStatusValue(_ available: Bool, _ configured: Bool = true) -> String {
        if !configured { return "disabled" }
        return available ? "ok" : "down"
    }

    func rollupServiceHealth(_ services: [JSON]) -> String {
        let active = services.filter { $0["status"].stringValue != "disabled" }
        if active.isEmpty { return "disabled" }
        if active.contains(where: { $0["status"].stringValue == "down" }) { return "down" }
        if active.contains(where: { $0["status"].stringValue == "degraded" }) { return "degraded" }
        return "ok"
    }

    func safeServiceUrl(_ rawValue: JSON) -> String {
        let raw = JS.compactString(rawValue, "", 512)
        if raw.isEmpty { return "" }
        guard var parsed = WebURL(raw) else { return "[redacted-invalid-endpoint]" }
        parsed.username = ""
        parsed.password = ""
        parsed.query = nil
        parsed.fragment = nil
        var text = parsed.description
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func roachClawServiceHealthState(ollama: JSON, openclaw: JSON, models: [JSON], agent: JSON, services: [JSON],
                                     uploadLimits: JSON, memoryProvider: JSON, embeddingLanes: JSON, scopedToolBridge: JSON) -> JSON {
        let memoryProviders = memoryProvider["providers"].array
        let enabledMemoryProviders = memoryProviders.filter { $0["enabled"].truthy }
        let embeddingActive = (embeddingLanes["stats"]["activeLaneCount"] || 0).jsNumber
        let embeddingHealthy = (embeddingLanes["stats"]["healthyLaneCount"] || 0).jsNumber
        let updateStage = (systemUpdateStatus["stage"] || systemUpdateStatus["status"] || "").jsString.lowercased()
        let updateIsError = ["error", "failed"].contains(updateStage)
        let serviceCatalogReady = !services.isEmpty
        let embeddingHealthyFlag = embeddingLanes["health"]["healthy"].truthy
        let report: [JSON] = [
            [
                "name": "ollama",
                "label": "RoachInference local model runner",
                "status": JSON(serviceHealthStatusValue(ollama["available"].truthy, true)),
                "detail": JSON(ollama["available"].truthy
                    ? "Local model runner is reachable."
                    : "Local model runner is not reachable yet; RoachClaw can still show local state."),
                "meta": [
                    "provider": "ollama",
                    "endpoint": JSON(safeServiceUrl(ollama["baseUrl"] || JSON(modelServerBaseUrl))),
                    "modelCount": JSON(models.count),
                ],
            ],
            [
                "name": "openclaw-compatibility",
                "label": "OpenClaw compatibility lane",
                "status": JSON(openclaw["available"].truthy ? "ok" : "disabled"),
                "detail": JSON(openclaw["available"].truthy
                    ? "Compatibility endpoint is reachable."
                    : "Compatibility lane is optional; native RoachClaw does not depend on it."),
                "meta": [
                    "provider": "openclaw",
                    "endpoint": JSON(safeServiceUrl(openclaw["baseUrl"] || JSON(config.openClawBaseUrl))),
                ],
            ],
            [
                "name": "roachclaw-native-agent",
                "label": "RoachClaw native agent",
                "status": "ok",
                "detail": "Native agent lane is available without Python, Flask, Electron, or WebUI.",
                "meta": [
                    "runtime": agent["runtime"] || "native-api",
                    "configuredModel": agent["configuredModel"] || JSON(defaultModel),
                    "resolvedModel": agent["resolvedModel"] || nil,
                ],
            ],
            [
                "name": "roachbrain-memory",
                "label": "RoachBrain memory provider",
                "status": JSON(enabledMemoryProviders.isEmpty ? "degraded" : "ok"),
                "detail": JSON(enabledMemoryProviders.isEmpty
                    ? "No enabled memory provider is visible."
                    : "At least one memory provider is enabled; RoachBrain native memory is the default."),
                "meta": ["providerCount": JSON(memoryProviders.count), "enabledCount": JSON(enabledMemoryProviders.count)],
            ],
            [
                "name": "embedding-lanes",
                "label": "Embedding lanes",
                "status": JSON(embeddingHealthyFlag ? "ok" : "degraded"),
                "detail": JSON(embeddingHealthyFlag ? "At least one embedding lane is healthy." : "Embedding lanes need attention before promotion."),
                "meta": [
                    "laneCount": embeddingLanes["stats"]["laneCount"] || 0,
                    "activeLaneCount": JSON(embeddingActive),
                    "healthyLaneCount": JSON(embeddingHealthy),
                ],
            ],
            [
                "name": "intake-policy",
                "label": "Intake policy",
                "status": "ok",
                "detail": "Upload, speech, media, calendar, and installer limits are enforced before large work can freeze the app.",
                "meta": ["policy": uploadLimits["policy"], "limitCount": JSON(uploadLimits["limits"].array.count)],
            ],
            [
                "name": "scoped-tool-bridge",
                "label": "Scoped tool bridge",
                "status": JSON(scopedToolBridge["localOnly"].truthy && scopedToolBridge["approvalRequired"].truthy ? "ok" : "degraded"),
                "detail": "Tool access stays loopback-only with explicit approval and scoped route metadata.",
                "meta": ["scopeCount": JSON(scopedToolBridge["scopes"].array.count), "endpointCount": JSON(scopedToolBridge["endpoints"].array.count)],
            ],
            [
                "name": "service-catalog",
                "label": "Service catalog",
                "status": JSON(serviceCatalogReady ? "ok" : "degraded"),
                "detail": JSON(serviceCatalogReady ? "Native service catalog is present for runtime controls." : "Native service catalog is empty."),
                "meta": ["serviceCount": JSON(services.count), "installedCount": JSON(services.filter { $0["installed"].truthy }.count)],
            ],
            [
                "name": "updates",
                "label": "Update lane",
                "status": JSON(updateIsError ? "degraded" : "ok"),
                "detail": systemUpdateStatus["message"] || "No update in progress.",
                "meta": ["stage": systemUpdateStatus["stage"] || systemUpdateStatus["status"] || "idle"],
            ],
        ]
        return [
            "schema": "org.roachnet.roachclaw.service-health.v1",
            "source": "github-upstream-service-health-native-rewrite",
            "upstreamModule": "src/service_health.py",
            "route": "/api/roachclaw/diagnostics/services",
            "overall": JSON(rollupServiceHealth(report)),
            "services": .array(report),
            "summaryItems": .array(report.map { JSON("\($0["label"].jsString): \($0["status"].jsString)") }),
            "timestamp": JSON(JS.isoNow()),
            "budgets": [
                "probeTimeoutMs": JSON(config.serviceHealthProbeTimeoutMs),
                "networkProbes": "bounded-non-intrusive-loopback-only",
                "secretPolicy": "redacted-endpoints-no-raw-exceptions",
            ],
            "defaultPosture": "local-health-report-no-test-push-no-network-search",
        ]
    }

    // MARK: Operations

    func roachClawOperationsState(ollama: JSON, openclaw: JSON, models: [JSON], modelNames: [String], agent: JSON) -> JSON {
        let now = JS.isoNow()
        let jobs: [JSON] = downloadJobsSnapshot().map { job in
            ["id": job["jobId"], "kind": job["filetype"], "status": job["status"] || "queued", "progress": job["progress"], "target": job["filepath"], "updatedAt": job["updatedAt"] || nil]
        }
        let contacts = roachClawContactsState()
        let tasks = roachClawTaskState()
        let calendar = roachClawCalendarState()
        let reports = roachClawReportsState()
        let memories = roachClawMemoriesState()
        let skills = roachClawSkillsState()
        let editorDrafts = roachClawEditorDraftsState()
        let migrationDocumentTools = roachClawMigrationDocumentToolsState()
        let searchCache = roachClawSearchCacheState()
        let gallery = roachClawGalleryState()
        let webhooks = roachClawWebhooksState()
        let agentRuns = roachClawAgentRunsState()
        let contextCompactions = roachClawContextCompactionsState()
        let toolIndex = roachClawToolIndexState()
        let events = roachClawEventsState()
        let mail = roachClawMailState()
        let presets = roachClawPresetsState()
        let signatures = roachClawSignaturesState()
        let apiTokens = roachClawPublicApiTokensState()
        let cloudProviders = roachClawPublicCloudProviderKeysState()
        let backups = roachClawBackupsState()
        let userTime = roachClawUserTimeState()
        let cookbookServe = roachClawCookbookServeState()
        let readiness = roachClawReadinessState()
        let contextBudget = roachClawContextBudgetState()
        let scopedToolBridge = roachClawScopedToolBridgeState()
        let tlsOverrides = roachClawTlsOverridesState()
        let uploadLimits = roachClawUploadLimitsState()
        let memoryProvider = roachClawMemoryProviderState()
        let providerOAuth = roachClawProviderOAuthState()
        let embeddingLanes = roachClawEmbeddingLanesState()
        let toolPolicy = roachClawToolPolicyState()
        let serviceHealth = roachClawServiceHealthState(
            ollama: ollama, openclaw: openclaw, models: models, agent: agent, services: serviceCatalog,
            uploadLimits: uploadLimits, memoryProvider: memoryProvider, embeddingLanes: embeddingLanes, scopedToolBridge: scopedToolBridge
        )
        let shell = roachClawShellSurfaces(
            tasks: tasks, calendar: calendar, reports: reports, memories: memories, skills: skills, editorDrafts: editorDrafts,
            searchCache: searchCache, gallery: gallery, webhooks: webhooks, agentRuns: agentRuns, contextCompactions: contextCompactions,
            toolIndex: toolIndex, events: events, mail: mail, presets: presets, backups: backups
        )

        func first12(_ value: JSON) -> JSON { .array(Array(value.array.prefix(12))) }
        func first6(_ value: JSON) -> [JSON] { Array(value.array.prefix(6)) }
        let taskRecords = tasks["tasks"].array
        let openTasks = taskRecords.filter { !NativeRuntime.closedTaskStatuses.contains(lowerStatus($0)) }.count
        let activeJobs = jobs.filter { ["queued", "downloading"].contains($0["status"].jsString) }.count
        let runRecords = agentRuns["runs"].array
        let runningRuns = runRecords.filter { ["running", "queued"].contains(lowerStatus($0)) }.count
        let draftRecords = editorDrafts["drafts"].array
        let readinessChecks = readiness["checks"].object
        let serviceItems = serviceHealth["services"].array
        let warnings: [JSON] = (ollama["available"].truthy ? [] : [JSON("\(modelServerName) is not reachable yet; local chat wakes up when it starts.")])
            + (modelNames.isEmpty ? ["No local model packs are installed yet."] : [])

        return [
            "schema": "org.roachnet.roachclaw.operations.v1",
            "updatedAt": JSON(now),
            "diagnostics": [
                "status": JSON(ollama["available"].truthy ? "ready" : "needs-runtime"),
                "probes": [
                    ["id": "ollama", "label": JSON(modelServerIsOllama ? "Ollama" : "RoachInference model server"), "available": JSON(ollama["available"].truthy), "detail": ollama["error"] || "Local model server probe."],
                    ["id": "openclaw", "label": "OpenClaw compatibility lane", "available": JSON(openclaw["available"].truthy), "detail": openclaw["error"] || "Compatibility probe only; RoachClaw is native-first."],
                    ["id": "roachclaw-native-agent", "label": "RoachClaw native agent", "available": true, "detail": JSON("\((agent["runtime"] || "native agent").jsString) is available without a WebUI bridge.")],
                ],
                "warnings": .array(warnings),
            ],
            "serviceHealth": [
                "status": serviceHealth["overall"],
                "count": JSON(serviceItems.count),
                "active": JSON(serviceItems.filter { $0["status"].stringValue == "ok" }.count),
                "route": "roachnet://runtime/service-health",
                "summaryItems": serviceHealth["summaryItems"],
                "detail": "Native degraded-state report for the model runner, agent, memory, embeddings, intake policy, service catalog, tools, and updates.",
                "actions": ["Run service health", "Inspect degraded lanes", "Copy safe report"],
                "report": serviceHealth,
            ],
            "contacts": [
                "status": "local-first",
                "storagePath": JSON(roachClawVaultPath("contacts.json")),
                "recordCount": JSON(contacts["contacts"].array.count),
                "records": first12(contacts["contacts"]),
                "scopes": ["local-address-book", "reply-recipient-context", "account-owned-routing"],
                "notes": ["Contacts are modeled as a local context lane; no hosted CRM is required."],
            ],
            "hooks": [
                "status": "armed-local-only",
                "storagePath": JSON(roachClawVaultPath("hooks.json")),
                "endpoints": [
                    ["id": "companion-install", "method": "POST", "path": "/api/companion/install", "scope": "app-store-install"],
                    ["id": "agent-run", "method": "POST", "path": "/api/roachclaw/agent/run", "scope": "approval-gated-agent-run"],
                ],
                "secretsPolicy": "local-redacted",
            ],
            "jobs": [
                "status": JSON(activeJobs > 0 ? "running" : "idle"),
                "update": systemUpdateStatus,
                "downloads": .array(jobs),
                "scheduler": [
                    "status": "local-queue",
                    "storagePath": JSON(roachClawVaultPath("jobs.json")),
                    "pending": JSON(activeJobs + openTasks),
                ],
            ],
            "notesTasks": [
                "status": JSON(taskRecords.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("tasks.json")),
                "count": JSON(taskRecords.count),
                "open": JSON(openTasks),
                "records": first12(tasks["tasks"]),
            ],
            "calendar": [
                "status": JSON(calendar["events"].array.isEmpty ? "empty" : "planned"),
                "storagePath": JSON(roachClawVaultPath("calendar.json")),
                "count": JSON(calendar["events"].array.count),
                "records": first12(calendar["events"]),
            ],
            "reports": [
                "status": JSON(reports["reports"].array.isEmpty ? "ready" : "tracking"),
                "root": JSON(roachClawVaultPath("reports")),
                "formats": ["markdown", "json", "pdf-ready-html"],
                "templates": ["research-brief", "model-compare", "diagnostics-report", "vault-source-map"],
                "count": JSON(reports["reports"].array.count),
                "records": first12(reports["reports"]),
            ],
            "memories": [
                "status": JSON(memories["memories"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("memories.json")),
                "count": JSON(memories["memories"].array.count),
                "records": first12(memories["memories"]),
            ],
            "skills": [
                "status": JSON(skills["skills"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("skills.json")),
                "count": JSON(skills["skills"].array.count),
                "records": first12(skills["skills"]),
            ],
            "editorDrafts": [
                "status": JSON(draftRecords.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("editor-drafts.json")),
                "count": JSON(draftRecords.count),
                "open": JSON(draftRecords.filter { !NativeRuntime.closedDraftStatuses.contains(lowerStatus($0)) }.count),
                "records": first12(editorDrafts["drafts"]),
            ],
            "migrationDocumentTools": migrationDocumentTools,
            "searchCache": [
                "status": JSON(searchCache["entries"].array.isEmpty ? "empty" : "warm"),
                "storagePath": JSON(roachClawVaultPath("search-cache.json")),
                "count": JSON(searchCache["entries"].array.count),
                "records": first12(searchCache["entries"]),
            ],
            "gallery": [
                "status": JSON(gallery["assets"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("gallery.json")),
                "count": JSON(gallery["assets"].array.count),
                "records": first12(gallery["assets"]),
            ],
            "webhooks": [
                "status": JSON(webhooks["webhooks"].array.contains { $0["isActive"].truthy } ? "armed" : "empty"),
                "storagePath": JSON(roachClawVaultPath("webhooks.json")),
                "count": JSON(webhooks["webhooks"].array.count),
                "active": JSON(webhooks["webhooks"].array.filter { $0["isActive"].truthy }.count),
                "records": first12(webhooks["webhooks"]),
                "secretsPolicy": "sha256-digest-only-raw-secret-never-exported",
            ],
            "agentRuns": [
                "status": JSON(runningRuns > 0 ? "running" : (runRecords.isEmpty ? "empty" : "tracked")),
                "storagePath": JSON(roachClawVaultPath("agent-runs.json")),
                "count": JSON(runRecords.count),
                "active": JSON(runningRuns),
                "records": first12(agentRuns["runs"]),
                "retention": "local-replay-buffer-metadata",
            ],
            "contextCompactions": [
                "status": JSON(contextCompactions["compactions"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("context-compactions.json")),
                "count": JSON(contextCompactions["compactions"].array.count),
                "records": first12(contextCompactions["compactions"]),
                "retention": "summary-plus-token-budget",
            ],
            "toolIndex": [
                "status": JSON(toolIndex["tools"].array.isEmpty ? "empty" : "indexed"),
                "storagePath": JSON(roachClawVaultPath("tool-index.json")),
                "count": JSON(toolIndex["tools"].array.count),
                "active": JSON(toolIndex["tools"].array.filter { $0["enabled"].truthy }.count),
                "records": first12(toolIndex["tools"]),
                "selectionPolicy": "local-ranked-tool-cards",
            ],
            "events": [
                "status": JSON(events["events"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("events.json")),
                "count": JSON(events["events"].array.count),
                "active": JSON(events["events"].array.filter { $0["enabled"].truthy }.count),
                "records": first12(events["events"]),
                "delivery": "local-counter-gated-actions",
            ],
            "commandDeck": shell["commandDeck"],
            "contextRail": shell["contextRail"],
            "vaultNavigator": shell["vaultNavigator"],
            "agentMonitor": shell["agentMonitor"],
            "orchestrationDashboard": shell["orchestrationDashboard"],
            "mail": [
                "status": JSON(mail["messages"].array.isEmpty && mail["drafts"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("mail.json")),
                "count": JSON(mail["messages"].array.count + mail["drafts"].array.count),
                "messages": JSON(mail["messages"].array.count),
                "drafts": JSON(mail["drafts"].array.count),
                "records": .array(first6(mail["drafts"]) + first6(mail["messages"])),
            ],
            "presets": [
                "status": JSON(presets["templates"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("presets.json")),
                "count": JSON(presets["templates"].array.count),
                "templates": first12(presets["templates"]),
            ],
            "signatures": [
                "status": JSON(signatures["signatures"].array.isEmpty ? "empty" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("signatures.json")),
                "count": JSON(signatures["signatures"].array.count),
                "records": first12(signatures["signatures"]),
            ],
            "apiTokens": [
                "status": JSON(apiTokens["tokens"].array.contains { $0["isActive"].truthy } ? "armed" : "empty"),
                "storagePath": JSON(roachClawVaultPath("api-tokens.json")),
                "count": JSON(apiTokens["tokens"].array.count),
                "active": JSON(apiTokens["tokens"].array.filter { $0["isActive"].truthy }.count),
                "records": first12(apiTokens["tokens"]),
                "secretsPolicy": "sha256-hash-only-token-returned-on-create",
            ],
            "cloudProviders": [
                "status": JSON(cloudProviders["active"].truthy ? "user-armed" : "local-default"),
                "storagePath": JSON(roachClawVaultPath("cloud-provider-keys.json")),
                "count": cloudProviders["count"],
                "active": cloudProviders["active"],
                "configured": cloudProviders["configured"],
                "records": cloudProviders["providers"],
                "secretsPolicy": cloudProviders["secretsPolicy"],
                "defaultPosture": "local-first-roachclaw-with-optional-user-owned-cloud-keys",
            ],
            "workspaceBrowser": [
                "status": "ready",
                "root": JSON(roachClawWorkspaceBrowseRoot()),
                "count": 0,
                "route": "roachnet://dev/workspace",
                "hotkey": "Cmd-Shift-W",
                "summaryItems": ["directories only", "dotfiles hidden", "symlinks not followed"],
                "detail": "Native workspace picker for Dev and RoachClaw context. It lists folders without exposing the rest of the filesystem to a WebUI bridge.",
                "actions": ["Browse workspace", "Attach folder", "Pin project", "Send to RoachClaw"],
            ],
            "userTime": [
                "status": JSON(userTime["configured"].truthy ? "configured" : "system-default"),
                "storagePath": JSON(roachClawVaultPath("user-time.json")),
                "count": JSON(userTime["configured"].truthy ? 1 : 0),
                "route": "roachnet://settings/time",
                "summaryItems": .array([userTime["timeZoneName"], userTime["utcOffset"], userTime["localDateTime"]].filter { $0.truthy }),
                "detail": "Local time context for schedulers and RoachClaw prompts, so relative dates stop guessing at your calendar.",
                "actions": ["Set timezone", "Refresh clock context", "Attach to prompt"],
            ],
            "cookbookServeLifecycle": [
                "status": JSON(cookbookServe["active"].truthy ? "scheduled" : "idle"),
                "storagePath": JSON(roachClawVaultPath("cookbook-serve-schedules.json")),
                "count": JSON(cookbookServe["schedules"].array.count),
                "active": cookbookServe["active"],
                "queued": cookbookServe["pending"],
                "route": "roachnet://roachclaw/cookbook",
                "summaryItems": [
                    JSON("\(cookbookServe["schedules"].array.count) schedules"),
                    JSON("\(cookbookServe["active"].jsString) active"),
                    JSON("\(cookbookServe["pending"].jsString) waiting"),
                ],
                "detail": "Native model-serve scheduling and stop windows rewritten as RoachNet local state.",
                "actions": ["Schedule model", "Mirror calendar", "Stop expired serves", "Inspect progress"],
            ],
            "readiness": [
                "status": JSON(readiness["ready"].truthy ? "ready" : "needs-attention"),
                "storagePath": readinessChecks["storageRoot"]["path"] || JSON(storageRoot),
                "count": JSON(readinessChecks.count),
                "active": JSON(readinessChecks.values.filter { $0["ok"].truthy }.count),
                "route": "roachnet://runtime/readiness",
                "summaryItems": [
                    JSON(readiness["ready"].truthy ? "all checks passed" : "checks need review"),
                    JSON(readiness["localFirst"].truthy ? "local-first" : "remote storage warning"),
                    JSON("\(readinessChecks.count) checks"),
                ],
                "detail": "Native readiness probe for storage, vault, runtime state, and local-first posture before RoachClaw takes real work.",
                "actions": ["Run readiness", "Open storage", "Inspect warnings"],
            ],
            "contextBudget": [
                "status": JSON(contextBudget["explicit"].truthy ? "user-set" : "adaptive"),
                "storagePath": JSON(roachClawVaultPath("context-budget.json")),
                "count": contextBudget["effectiveBudget"],
                "active": contextBudget["modelContextLength"],
                "route": "roachnet://roachclaw/context-budget",
                "summaryItems": [
                    JSON("\(contextBudget["effectiveBudget"].jsString) tokens"),
                    JSON(contextBudget["explicit"].truthy ? "explicit" : "adaptive"),
                    JSON("\(contextBudget["headroomPercent"].jsString)% headroom"),
                ],
                "detail": "Adaptive input-token budget so long-context local models are not silently capped at tiny defaults.",
                "actions": ["Tune budget", "Probe model window", "Apply headroom"],
            ],
            "urlSafety": [
                "status": "armed",
                "count": 2,
                "route": "roachnet://settings/url-safety",
                "summaryItems": ["http/https only", "metadata IPs blocked", "private block optional"],
                "detail": "Checks user-supplied outbound URLs before RoachClaw or integrations fetch them.",
                "actions": ["Check URL", "Block metadata targets", "Review provider endpoint"],
            ],
            "scopedToolBridge": [
                "status": "ready",
                "storagePath": JSON(roachClawVaultPath("scoped-tool-bridge.json")),
                "count": JSON(scopedToolBridge["scopes"].array.count),
                "active": JSON(scopedToolBridge["endpoints"].array.count),
                "route": "roachnet://roachclaw/tools",
                "summaryItems": .array(Array(scopedToolBridge["scopes"].array.prefix(4))),
                "detail": "Native scoped tool bridge for local actions, designed without shipping a Python plugin server.",
                "actions": ["List scopes", "Inspect endpoints", "Require approval", "Export manifest"],
            ],
            "tlsOverrides": [
                "status": JSON(tlsOverrides["configured"].truthy ? (tlsOverrides["valid"].truthy ? "configured" : "invalid-path") : "default-trust"),
                "storagePath": JSON(roachClawVaultPath("tls-overrides.json")),
                "count": JSON(tlsOverrides["configured"].truthy ? 1 : 0),
                "active": JSON(tlsOverrides["valid"].truthy ? 1 : 0),
                "route": "roachnet://settings/provider-security",
                "summaryItems": .array([tlsOverrides["scope"], tlsOverrides["bundleLabel"]].filter { $0.truthy }),
                "detail": "Optional extra CA bundle metadata for user-owned provider routes. Verification stays on; there is no insecure off switch.",
                "actions": ["Set CA bundle", "Clear override", "Inspect scope"],
            ],
            "uploadLimits": [
                "status": "enforced",
                "count": JSON(uploadLimits["limits"].array.count),
                "route": "roachnet://vault/imports",
                "summaryItems": uploadLimits["summaryItems"],
                "detail": "Native request, upload, and download byte caps stay explicit so oversized imports fail cleanly instead of freezing the app.",
                "actions": ["Inspect limits", "Retry smaller file", "Open vault imports"],
            ],
            "memoryProvider": [
                "status": JSON(memoryProvider["providers"].array.contains { $0["enabled"].truthy } ? "native-provider" : "empty"),
                "storagePath": JSON(roachClawVaultPath("memory-provider.json")),
                "count": JSON(memoryProvider["providers"].array.count),
                "active": JSON(memoryProvider["providers"].array.filter { $0["enabled"].truthy }.count),
                "route": "roachnet://roachbrain/providers",
                "summaryItems": .array(Array(memoryProvider["providers"].array.map { $0["displayName"] }.prefix(3))),
                "detail": "Provider-neutral memory contract rewritten as RoachBrain local state; external memory systems stay opt-in.",
                "actions": ["List providers", "Recall memory", "Write local memory", "Audit tools"],
            ],
            "providerOAuth": [
                "status": JSON(providerOAuth["flows"].array.contains { $0["needsUserAction"].truthy } ? "needs-user-action" : "idle"),
                "storagePath": JSON(roachClawVaultPath("provider-oauth.json")),
                "count": JSON(providerOAuth["flows"].array.count),
                "active": JSON(providerOAuth["flows"].array.filter { $0["isActive"].truthy }.count),
                "route": "roachnet://settings/provider-oauth",
                "summaryItems": .array(Array(providerOAuth["flows"].array.map { $0["provider"] }.prefix(4))),
                "detail": "OAuth metadata for user-owned remote tools. Tokens are not exported, and local RoachClaw remains the default lane.",
                "actions": ["Start user flow", "Cancel pending flow", "Review scopes"],
            ],
            "embeddingLanes": [
                "status": embeddingLanes["health"]["status"],
                "storagePath": JSON(roachClawVaultPath("embedding-lanes.json")),
                "count": JSON(embeddingLanes["lanes"].array.count),
                "active": JSON(embeddingLanes["lanes"].array.filter { $0["enabled"].truthy }.count),
                "route": "roachnet://roachbrain/embedding-lanes",
                "summaryItems": .array(Array(embeddingLanes["lanes"].array.map { lane -> JSON in
                    let dimension = lane["dimension"]
                    let detail = dimension.truthy ? "\(dimension.jsString)d" : lane["health"]["status"].jsString
                    return JSON("\(lane["label"].jsString): \(detail)")
                }.prefix(4))),
                "detail": "Separate local and custom embedding lanes with fingerprints, reset safety, health, and stats, kept as native RoachBrain state.",
                "actions": ["Inspect lanes", "Check fingerprints", "Reset safely", "Reindex local memory"],
            ],
            "toolPolicy": [
                "status": JSON(toolPolicy["mode"].stringValue == "guide_only" ? "guide-only" : "enforced"),
                "storagePath": JSON(roachClawVaultPath("tool-policy.json")),
                "count": toolPolicy["knownToolCount"],
                "active": toolPolicy["disabledCount"],
                "route": "roachnet://roachclaw/tool-policy",
                "summaryItems": toolPolicy["display"]["summaryItems"],
                "detail": "Per-turn tool policy metadata for guide-only detection, prompt hiding, disabled tools, and native display.",
                "actions": ["Evaluate prompt", "Hide disabled tools", "Show enforcement reason", "Review scopes"],
            ],
            "backups": [
                "status": JSON(backups["snapshots"].array.isEmpty ? "ready" : "tracking"),
                "storagePath": JSON(roachClawVaultPath("backups.json")),
                "count": JSON(backups["snapshots"].array.count),
                "snapshots": first12(backups["snapshots"]),
            ],
            "uploads": [
                "status": "vault-scoped",
                "root": JSON(Path.join(storageRoot, "Vault")),
                "maxRequestBytes": JSON(config.maxRequestBodyBytes),
                "ownership": "local-user",
                "isolation": "sanitize-name-and-copy-into-vault",
            ],
            "preferences": [
                "status": "native-settings",
                "storagePath": JSON(Path.join(config.runtimeStateRoot, "roachclaw-preferences.json")),
                "scrubPolicy": "export-redacts-local-secrets-and-machine-paths",
                "appearance": ["system", "dark", "high-contrast"],
            ],
            "adminRecovery": [
                "status": "local-owner-required",
                "actions": ["first-run-owner-claim", "reset-local-agent-state", "scrub-settings-export"],
                "remoteAccess": false,
            ],
            "models": [
                "count": JSON(models.count),
                "installed": jsonStrings(modelNames),
            ],
        ]
    }

    // MARK: Account, sync, services

    func accountState() -> JSON {
        let base: JSON = [
            "linked": false,
            "provider": "local",
            "portalUrl": "https://roachnet.org/",
            "accountId": nil,
            "email": nil,
            "displayName": nil,
            "status": "local-only",
            "settingsSyncEnabled": false,
            "savedAppsSyncEnabled": false,
            "hostedChatEnabled": false,
            "aliasHost": JSON(config.env("ROACHNET_LOCAL_HOSTNAME").flatMap { $0.isEmpty ? nil : $0 } ?? "RoachNet"),
            "bridgeUrl": nil,
            "runtimeOrigin": nil,
            "linkedAt": nil,
            "lastSeenAt": nil,
            "lastUpdatedAt": nil,
            "notes": ["Native runtime is local-only unless the user arms online account metadata."],
        ]
        return base.merging(storedCompanionAccount())
    }

    func roachSyncState() -> JSON {
        let base: JSON = [
            "enabled": false,
            "provider": "local",
            "networkName": "RoachSync",
            "deviceName": JSON(Host.hostname),
            "deviceId": JSON(Host.hostname),
            "status": "local-only",
            "folderId": "roachnet-storage",
            "folderPath": JSON(storageRoot),
            "guiUrl": nil,
            "apiUrl": nil,
            "transportMode": "native-local",
            "secureOverlay": true,
            "notes": ["RoachSync is available when the user arms the companion lane."],
            "peers": [],
            "lastUpdatedAt": nil,
        ]
        return base.merging(storedCompanionRoachSync())
    }

    var serviceCatalog: [JSON] {
        [
            ["service_name": "roachnet_kiwix_serve", "friendly_name": "RoachNet Library", "description": "Offline encyclopedias, field manuals, and reference archives staged inside RoachNet.", "icon": "IconBooks", "powered_by": "Kiwix", "ui_location": "8090", "display_order": 1],
            ["service_name": "roachnet_kolibri", "friendly_name": "RoachNet Academy", "description": "Structured offline education content and coursework surfaced through RoachNet.", "icon": "IconSchool", "powered_by": "Kolibri", "ui_location": "8300", "display_order": 2],
            ["service_name": "roachnet_ollama", "friendly_name": "RoachNet Chat", "description": "Local AI chat and model tooling managed from the RoachNet command grid.", "icon": "IconWand", "powered_by": JSON(modelServerIsOllama ? "Ollama" : "RoachInference"), "ui_location": "/chat", "display_order": 3],
            ["service_name": "roachnet_roachsync", "friendly_name": "RoachSync", "description": "Private sync for the RoachNet vault, settings, and future shared installs.", "icon": "IconArrowsExchange", "powered_by": "Native companion bridge", "ui_location": "8384", "display_order": 4],
            ["service_name": "roachnet_flatnotes", "friendly_name": "RoachNet Notes", "description": "Fast local notes for fragments, checklists, and working references on the same machine.", "icon": "IconNotes", "powered_by": "Flat file vault", "ui_location": "/vault", "display_order": 10],
            ["service_name": "roachnet_cyberchef", "friendly_name": "RoachNet Data Lab", "description": "Encoding, decoding, and analysis tools adapted for RoachNet field workflows.", "icon": "IconChefHat", "powered_by": "Native utilities", "ui_location": "/dev", "display_order": 11],
        ]
    }

    func systemServices(_ ollamaStatus: JSON? = nil) -> [JSON] {
        let ollama = ollamaStatus ?? providerStatus("ollama", modelServerBaseUrl)
        return serviceCatalog.map { service in
            let name = service["service_name"].jsString
            let installed = name == "roachnet_ollama" ? ollama["available"].truthy : ["roachnet_flatnotes", "roachnet_cyberchef"].contains(name)
            var record = service
            record["installed"] = JSON(installed)
            record["installation_status"] = JSON(installed ? "installed" : "idle")
            record["status"] = JSON(installed ? "running" : "available")
            return record
        }
    }

    // MARK: Companion payloads

    func companionBootstrapState() -> JSON {
        [
            "appName": "RoachNet",
            "machineName": JSON(Host.hostname),
            "appsCatalogUrl": "https://apps.roachnet.org/app-store-catalog.json",
            "sessions": [],
            "account": accountState(),
            "runtime": companionRuntimeState(),
            "vault": companionVaultState(),
        ]
    }

    func companionRuntimeState() -> JSON {
        let status = roachClawStatus()
        let system = systemInfo()
        let services = systemServices(status["ollama"])
        let models: JSON = status["modelRecords"].isArray
            ? status["modelRecords"]
            : .array(status["installedModels"].array.map { ["name": $0, "size": nil] })
        var issues: [JSON] = []
        if !status["ollama"]["available"].truthy {
            issues.append(["path": "/api/ollama", "error": JSON("\(modelServerName) is not reachable yet; local chat will warm up after it starts.")])
        }
        if models.array.isEmpty {
            issues.append(["path": "/api/ollama/installed-models", "error": "No local model packs are installed yet."])
        }
        return [
            "systemInfo": system,
            "system": system,
            "providers": [
                "providers": [
                    "ollama": status["ollama"],
                    "openclaw": status["openclaw"],
                    "roachclawNativeAgent": [
                        "provider": "roachclawNativeAgent",
                        "available": true,
                        "source": "native-api",
                        "baseUrl": nil,
                        "error": nil,
                        "native": true,
                        "runtime": status["agent"]["runtime"],
                    ],
                ],
            ],
            "roachClaw": status,
            "account": accountState(),
            "roachTail": roachTailState(hideJoinCode: true),
            "roachSync": roachSyncState(),
            "services": .array(services),
            "downloads": .array(downloadJobsSnapshot()),
            "installedModels": models,
            "issues": .array(issues),
            "benchmark": benchmarkStatus,
        ]
    }

    func companionVaultState() -> JSON {
        let vaultPath = Path.join(storageRoot, "Vault")
        return [
            "vaultPath": JSON(vaultPath),
            "locked": JSON(vaultIsLocked),
            "knowledgeFiles": jsonStrings(listVaultKnowledgeFiles(vaultPath)),
            "roachBrain": [],
        ]
    }

    /// An encrypted Vault that is locked: the app leaves this marker in the
    /// empty, read-only folder the encrypted image mounts over (see the app's
    /// VaultEncryptionManager). The marker is hidden while the Vault is open.
    static let vaultLockedMarker = ".roachnet-vault-locked"
    var vaultIsLocked: Bool { Files.exists(Path.join(storageRoot, "Vault", NativeRuntime.vaultLockedMarker)) }

    /// Files the system or RoachNet makes in the Vault that aren't knowledge.
    static let vaultSystemNames: Set<String> = [vaultLockedMarker, ".metadata_never_index", ".fseventsd", ".Trashes",
                                                ".Spotlight-V100", ".TemporaryItems", ".DS_Store"]

    func isReservedVaultPath(_ relativePath: String) -> Bool {
        if NativeRuntime.vaultSystemNames.contains(Path.basename(relativePath)) { return true }
        return JS.matches("^(?:roachtail|roachclaw)(?:[\\\\/]|$)", relativePath, caseInsensitive: true)
    }

    func listVaultKnowledgeFiles(_ root: String, limit: Int = 80) -> [String] {
        if Files.exists(Path.join(root, NativeRuntime.vaultLockedMarker)) { return [] }
        var output: [String] = []
        func walk(_ current: String, _ relativeRoot: String) {
            if output.count >= limit || !Files.exists(current) { return }
            let entries = Files.entries(current).sorted { JS.localeCompare($0.name, $1.name) < 0 }
            for entry in entries {
                let relativePath = relativeRoot.isEmpty ? entry.name : Path.join(relativeRoot, entry.name)
                if isReservedVaultPath(relativePath) { continue }
                let full = Path.join(current, entry.name)
                if entry.isDirectory {
                    walk(full, relativePath)
                } else if entry.isFile {
                    output.append(relativePath)
                }
                if output.count >= limit { return }
            }
        }
        walk(root, "")
        return output
    }

    // MARK: Catalog manifests

    func readJSONFile(_ candidates: [String], _ fallback: JSON) -> JSON {
        for candidate in candidates {
            let target = Path.isAbsolute(candidate) ? candidate : Path.join(config.repoRoot, candidate)
            if Files.exists(target), let parsed = JSON.read(contentsOf: target) { return parsed }
        }
        return fallback
    }

    func safeFileName(_ value: JSON, _ fallback: String = "download.bin") -> String {
        var cleaned = (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = JS.replace("[^A-Za-z0-9_.\\- ]+", in: cleaned, with: "_")
        cleaned = JS.replace("\\s+", in: cleaned, with: "-")
        cleaned = JS.slice(cleaned, 160)
        return cleaned.isEmpty ? fallback : cleaned
    }

    func fileNameForUrl(_ rawUrl: JSON, _ fallback: String) -> String {
        guard let parsed = WebURL(rawUrl.jsString) else { return fallback }
        return safeFileName(JSON(Path.basename(parsed.pathname)), fallback)
    }

    func descriptorUrlForSource(_ rawUrl: JSON, _ prefix: String) -> JSON {
        guard let parsed = WebURL(rawUrl.jsString) else { return rawUrl }
        let basename = Path.basename(parsed.pathname)
        if basename.isEmpty { return rawUrl }
        let descriptorName = JS.replace("\\.[^/.]+$", in: basename, with: ".json", caseInsensitive: true)
        let base = JS.replace("/+$", in: config.appsDownloadsBaseUrl, with: "")
        return JSON("\(base)/\(prefix)/\(descriptorName)")
    }

    func mapCollections() -> [JSON] {
        let manifest = loadCollection(.maps)
        let mapsRoot = Path.join(storageRoot, "maps", "pmtiles")
        return manifest["collections"].array.map { collection in
            let resources: [JSON] = collection["resources"].array.filter { !$0["unavailable"].truthy }.map { resource in
                [
                    "id": resource["id"],
                    "title": resource["title"],
                    "size_mb": resource["size_mb"] ?? nil,
                    "description": resource["description"] ?? nil,
                    "url": resource["url"] ?? nil,
                    "descriptorUrl": resource["url"].truthy ? descriptorUrlForSource(resource["url"], "maps/pmtiles") : nil,
                ]
            }
            let installedCount = resources.filter { resource in
                let fallback = "\(resource["id"].jsString).pmtiles"
                let filename = resource["url"].truthy ? fileNameForUrl(resource["url"], fallback) : fallback
                // 1.0.6 saved the same packs under their 2025-12 names.
                return Files.exists(Path.join(mapsRoot, filename))
                    || Files.exists(Path.join(mapsRoot, "\(resource["id"].jsString)_2025-12.pmtiles"))
            }.count
            return [
                "slug": collection["slug"],
                "name": collection["name"],
                "description": collection["description"] ?? nil,
                "minimumRoachNet": collection["minimumRoachNet"] ?? nil,
                "installed_count": JSON(installedCount),
                "total_count": JSON(resources.count),
                "resources": .array(resources),
            ]
        }
    }

    func educationCategories() -> [JSON] {
        let manifest = loadCollection(.kiwix)
        let zimRoot = Path.join(storageRoot, "zim")
        return manifest["categories"].array.map { category in
            [
                "slug": category["slug"],
                "name": category["name"],
                "description": category["description"] ?? nil,
                "installedTierSlug": installedTierSlug(category, zimRoot),
                "tiers": .array(category["tiers"].array.map { tier in
                    [
                        "name": tier["name"],
                        "slug": tier["slug"],
                        "description": tier["description"] ?? nil,
                        "recommended": JSON(tier["recommended"].truthy),
                        // A resource the publisher withdrew (`unavailable`) is not offered.
                        "resources": .array(tier["resources"].array.filter { !$0["unavailable"].truthy }.map { resource in
                            [
                                "id": resource["id"],
                                "title": resource["title"],
                                "size_mb": resource["size_mb"] ?? nil,
                                "description": resource["description"] ?? nil,
                                "url": resource["url"] ?? nil,
                                "descriptorUrl": resource["url"].truthy ? descriptorUrlForSource(resource["url"], "content/zim") : nil,
                            ]
                        }),
                    ]
                }),
            ]
        }
    }

    func installedTierSlug(_ category: JSON, _ zimRoot: String) -> JSON {
        for tier in category["tiers"].array {
            let installed = tier["resources"].array.contains { resource in
                guard resource["url"].truthy else { return false }
                return Files.exists(Path.join(zimRoot, fileNameForUrl(resource["url"], "\(resource["id"].jsString).zim")))
            }
            if installed { return tier["slug"] }
        }
        return .null
    }

    func wikipediaOptions() -> [JSON] {
        loadCollection(.wikipedia)["options"].array
            .filter { !$0["unavailable"].truthy }
    }

    func wikipediaSelectionPath() -> String { Path.join(storageRoot, "zim", "wikipedia-selection.json") }

    func wikipediaState() -> JSON {
        let currentSelection = JSON.read(contentsOf: wikipediaSelectionPath()) ?? .null
        return [
            "options": .array(wikipediaOptions().map { option in
                [
                    "id": option["id"],
                    "name": option["name"],
                    "description": option["description"] ?? nil,
                    "size_mb": option["size_mb"] ?? nil,
                    "url": option["url"] ?? nil,
                    "descriptorUrl": option["url"].truthy ? descriptorUrlForSource(option["url"], "content/wikipedia") : nil,
                ]
            }),
            "currentSelection": currentSelection,
        ]
    }

    func siteArchives() -> [JSON] {
        let records = readJSONFile([
            Path.join(storageRoot, "site-archives", "index.json"),
            "storage/site-archives/index.json",
            "admin/storage/site-archives/index.json",
        ], [])
        return records.array.map { archive in
            [
                "slug": archive["slug"],
                "title": archive["title"] ?? archive["slug"],
                "url": archive["url"] ?? archive["sourceUrl"] ?? archive["entryUrl"] ?? nil,
                "createdAt": archive["createdAt"] ?? nil,
            ]
        }.filter { $0["slug"].truthy }
    }

    // MARK: Releases

    func normalizeVersion(_ value: JSON) -> String {
        JS.replace("^v", in: (value.isNullish ? "" : value.jsString).trimmingCharacters(in: .whitespacesAndNewlines), with: "", caseInsensitive: true)
    }

    func compareVersions(_ left: String, _ right: String) -> Int {
        func parts(_ value: String) -> [Int] {
            normalizeVersion(JSON(value)).split(whereSeparator: { ".+-".contains($0) }).compactMap { part in
                let digits = part.prefix { $0.isNumber }
                return digits.isEmpty ? nil : Int(digits)
            }
        }
        let l = parts(left), r = parts(right)
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a > b { return 1 }
            if a < b { return -1 }
        }
        return 0
    }

    func resolveLatestRelease(force: Bool) throws -> JSON {
        if !force, let cache = latestReleaseCache, JS.nowMs() - cache.cachedAt < 10 * 60 * 1000 { return cache.release }
        let channel = config.trimmedEnv("ROACHNET_RELEASE_CHANNEL") ?? "stable"
        let releases = try HTTPClient.fetchJSON(config.githubReleasesApiUrl, headers: ["accept": "application/vnd.github+json"], timeoutMs: 12_000)
        let list = releases.array
        let release: JSON?
        if channel == "stable" {
            release = list.first { !$0["draft"].truthy && !$0["prerelease"].truthy }
        } else {
            release = list.first { !$0["draft"].truthy && ($0["prerelease"].truthy || ($0["tag_name"] || "").jsString.lowercased().contains(channel)) }
                ?? list.first { !$0["draft"].truthy }
        }
        guard let release else { throw RuntimeError("No \(channel) RoachNet release was found.") }
        let assets = release["assets"].array
        let asset = assets.first { JS.matches("RoachNet-Setup-macOS\\.dmg$", ($0["name"] || "").jsString, caseInsensitive: true) }
            ?? assets.first { JS.matches("RoachNet.*mac.*\\.(dmg|zip)$", ($0["name"] || "").jsString, caseInsensitive: true) }
        // The checksum sidecar published next to the installer is what the
        // update lane verifies the downloaded bytes against.
        let assetName = (asset ?? .undefined)["name"].stringValue ?? ""
        let sidecar = assets.first { ($0["name"] || "").jsString == assetName + ".sha256" }
        let resolved: JSON = [
            "currentVersion": JSON(version),
            "latestVersion": JSON(normalizeVersion(release["tag_name"] || release["name"] || JSON(version))),
            "name": release["name"] || release["tag_name"] || "RoachNet release",
            "pageUrl": release["html_url"] || JSON(config.githubReleasesUrl),
            "assetName": (asset ?? .undefined)["name"] || nil,
            "assetUrl": (asset ?? .undefined)["browser_download_url"] || release["html_url"] || JSON(config.githubReleasesUrl),
            "checksumUrl": (sidecar ?? .undefined)["browser_download_url"] || nil,
        ]
        latestReleaseCache = (JS.nowMs(), resolved)
        return resolved
    }

    func latestVersionResponse(force: Bool) -> JSON {
        do {
            let release = try resolveLatestRelease(force: force)
            let updateAvailable = compareVersions(release["latestVersion"].jsString, version) > 0
            return [
                "success": true,
                "updateAvailable": JSON(updateAvailable),
                "currentVersion": JSON(version),
                "latestVersion": release["latestVersion"],
                "message": JSON(updateAvailable ? "RoachNet \(release["latestVersion"].jsString) is available." : "RoachNet is current."),
                "releaseUrl": release["pageUrl"],
                "assetUrl": release["assetUrl"],
            ]
        } catch {
            return [
                "success": false,
                "updateAvailable": false,
                "currentVersion": JSON(version),
                "latestVersion": JSON(version),
                "message": JSON("Update check failed: \(error)"),
            ]
        }
    }
}
