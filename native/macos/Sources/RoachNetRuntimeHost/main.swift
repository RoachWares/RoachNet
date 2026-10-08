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
