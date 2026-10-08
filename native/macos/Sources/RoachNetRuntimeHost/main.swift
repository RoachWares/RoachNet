import Foundation
import RoachNetRuntime

// roachnet-runtime: the native RoachNet local runtime (loopback API, iOS
// companion bridge, RoachTail, downloads). Drop-in replacement for the former
// bundled-Node launcher; honours the same environment contract.
let arguments = CommandLine.arguments
let server = RuntimeServer()

if arguments.contains("--version") {
    print(RuntimeConfiguration.shared.version)
    exit(0)
}

if arguments.contains("--setup") {
    // RoachNet Setup backend (replaces the former Node installer service).
    let engine = SetupEngine()
    do {
        let setupServer = try engine.serve()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { setupServer.stop(); exit(0) }
        termination.resume()
        // Exit with the Setup app: an orphaned setup service is reparented to launchd.
        let parentWatch = DispatchSource.makeTimerSource(queue: .main)
        let parentAtStart = getppid()
        parentWatch.schedule(deadline: .now() + 2, repeating: 2)
        parentWatch.setEventHandler {
            if parentAtStart != 1 && getppid() == 1 { setupServer.stop(); exit(0) }
        }
        parentWatch.resume()
        withExtendedLifetime((setupServer, termination, parentWatch)) { dispatchMain() }
    } catch {
        FileHandle.standardError.write(Data("roachnet-runtime --setup: \(error)\n".utf8))
        exit(1)
    }
}

if arguments.contains("--stop") {
    try? FileManager.default.createDirectory(atPath: RuntimeConfiguration.shared.logRoot, withIntermediateDirectories: true)
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
