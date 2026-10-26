import Foundation
import RoachNetRuntime

do {
    let secrets = try LaunchSecrets.adopt()
    RuntimeConfiguration.shared = RuntimeConfiguration(
        environment: ProcessInfo.processInfo.environment, secrets: secrets)
} catch {
    FileHandle.standardError.write(Data("roachnet-runtime: \(error)\n".utf8))
    exit(78)
}

let arguments = CommandLine.arguments
let server = RuntimeServer()

if arguments.contains("--version") {
    print(RuntimeConfiguration.shared.version)
    exit(0)
}

if arguments.contains("--build-info") {
    let info: JSON = [
        "version": JSON(RuntimeConfiguration.shared.version),
        "sourceCommit": RuntimeBuildInfo.sourceCommit.map { JSON($0) } ?? .null,
    ]
    print(info.prettySerialized())
    exit(0)
}

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    return value.hasPrefix("--") ? nil : value
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        roachnet-runtime \(RuntimeConfiguration.shared.version) — native RoachNet runtime

          roachnet-runtime                      start the local runtime (env contract: HOST, PORT, ROACHNET_STORAGE_PATH, ...)
          roachnet-runtime --stop               stop a running runtime for this storage root
          roachnet-runtime --setup              serve the RoachNet Setup backend on loopback
          roachnet-runtime --install [options]  headless install (same staged workflow as RoachNet Setup)
              --install-path PATH   default ~/RoachNet
              --storage-path PATH   default <install-path>/storage
              --no-roachclaw        install without RoachClaw (no starter model, smaller space check)
              --launch              open RoachNet when the install finishes
              --profile NAME        install profile recorded in the config (e.g. homebrew-cask)
              --no-companion        leave the iOS companion bridge off until enabled in the app
          roachnet-runtime --provision-alias [--hosts-file PATH] [--print-command]
                                                point the RoachTail hostname at loopback
          roachnet-runtime --version            print the version
          roachnet-runtime --build-info         print the version and source commit as JSON
        """)
    exit(0)
}

if arguments.contains("--provision-alias") {
    let environment = ProcessInfo.processInfo.environment
    let hostname = RoachTailHostname.hostname(environment: environment)
    let hostsFile =
        argumentValue("--hosts-file") ?? environment["ROACHNET_HOSTS_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? "/etc/hosts"
    if arguments.contains("--print-command") {
        print(RoachTailHostname.privilegedShellCommand(hostname: hostname, hostsFile: hostsFile))
        exit(0)
    }
    do {
        let outcome = try RoachTailHostname.provision(
            hostname: hostname,
            hostsFile: hostsFile,
            allowPrivilegePrompt: arguments.contains("--interactive")
        )
        let payload: JSON = [
            "ok": true,
            "hostname": JSON(outcome.hostname),
            "hostsFile": JSON(outcome.hostsFile),
            "changed": JSON(outcome.changed),
            "resolved": outcome.resolved.map { JSON($0) } ?? .null,
        ]
        print(payload.serialized())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--install") {
    let engine = SetupEngine()
    RuntimeLog.redirect(to: engine.setupLogPath)
    var payload = JSONObject()
    if let installPath = argumentValue("--install-path") { payload["installPath"] = JSON(installPath) }
    if let storagePath = argumentValue("--storage-path") { payload["storagePath"] = JSON(storagePath) }
    payload["installRoachClaw"] = JSON(!arguments.contains("--no-roachclaw"))
    payload["autoLaunch"] = JSON(arguments.contains("--launch"))
    payload["useDockerContainerization"] = false
    if let profile = argumentValue("--profile") { payload["installProfile"] = JSON(profile) }
    if arguments.contains("--no-companion") { payload["companionEnabled"] = false }
    engine.onLog = { line in
        print(line)
        fflush(stdout)
    }
    do {
        let task = try engine.installSynchronously(.object(payload))
        if task["status"].stringValue == "completed" {
            print("RoachNet installed at \(task["result"]["installPath"].jsString)")
            exit(0)
        }
        switch task["errorKind"].stringValue ?? "" {
        case "setup-running", "lock-unavailable":
            FileHandle.standardError.write(Data("RoachNet Setup stopped: \(task["error"].jsString)\n".utf8))
            exit(SetupEngine.exitSetupRunning)
        case "stopped":
            FileHandle.standardError.write(Data("RoachNet Setup stopped: \(task["error"].jsString)\n".utf8))
            exit(SetupEngine.exitStopped)
        default:
            FileHandle.standardError.write(Data("RoachNet install failed: \(task["error"].jsString)\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("RoachNet install failed: \(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--setup") {
    let engine = SetupEngine()
    RuntimeLog.redirect(to: engine.setupLogPath)
    do {
        let setupServer = try engine.serve()
        var exitRequested = false
        func exitWhenIdle() {
            exitRequested = true
            if !engine.isInstalling {
                setupServer.stop()
                exit(0)
            }
        }
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { exitWhenIdle() }
        termination.resume()
        let parentWatch = DispatchSource.makeTimerSource(queue: .main)
        let parentAtStart = getppid()
        parentWatch.schedule(deadline: .now() + 1, repeating: 1)
        parentWatch.setEventHandler {
            if exitRequested || (parentAtStart != 1 && getppid() == 1) { exitWhenIdle() }
        }
        parentWatch.resume()
        withExtendedLifetime((setupServer, termination, parentWatch)) { dispatchMain() }
    } catch {
        FileHandle.standardError.write(Data("roachnet-runtime --setup: \(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--stop") {
    try? FileManager.default.createDirectory(
        atPath: RuntimeConfiguration.shared.logRoot, withIntermediateDirectories: true)
    server.stopExistingRuntime()
    exit(0)
}

do {
    try server.start()
} catch {
    RuntimeLog.write("fatal: \(error)")
    FileHandle.standardError.write(Data("roachnet-runtime: \(error)\n".utf8))
    exit(1)
}

dispatchMain()
