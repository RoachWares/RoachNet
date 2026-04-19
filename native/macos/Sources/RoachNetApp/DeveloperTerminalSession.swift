import Foundation
import Darwin

final class DeveloperTerminalSession: @unchecked Sendable {
    static let promptBootstrapLine = #"precmd() { print -r -- "__RN_PROMPT__${PWD}__STATUS__$?__"; }"#
    static let bootstrapScript = """
    export TERM=xterm-256color
    export COLORTERM=truecolor
    \(promptBootstrapLine)
    PROMPT=$'%F{75}%n@%m%f %F{82}%~%f %# '
    RPROMPT=''
    PROMPT_EOL_MARK=''
    PS2=$'%F{244}›%f '

    """

    enum SessionError: LocalizedError {
        case invalidLaunchDirectory
        case couldNotOpenPseudoTerminal(String)
        case couldNotFork
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .invalidLaunchDirectory:
                return "The requested terminal root does not exist."
            case let .couldNotOpenPseudoTerminal(details):
                return "RoachNet could not open a terminal session: \(details)"
            case .couldNotFork:
                return "RoachNet could not start the contained shell."
            case .couldNotWrite:
                return "RoachNet could not write to the terminal session."
            }
        }
    }

    private let launchDirectory: String
    private let environment: [String: String]
    private let ioQueue = DispatchQueue(label: "com.roachwares.roachnet.dev-terminal", qos: .userInitiated)

    private var masterDescriptor: Int32 = -1
    private var hasCleanedUp = false

    private(set) var processID: pid_t = 0

    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool {
        processID > 0
    }

    init(launchDirectory: String, environment: [String: String]) {
        self.launchDirectory = launchDirectory
        self.environment = environment
    }

    func start() throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: launchDirectory) else {
            throw SessionError.invalidLaunchDirectory
        }

        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(ws_row: 42, ws_col: 144, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw SessionError.couldNotOpenPseudoTerminal(String(cString: strerror(errno)))
        }

        let descriptorFlags = fcntl(master, F_GETFL)
        if descriptorFlags >= 0 {
            _ = fcntl(master, F_SETFL, descriptorFlags | O_NONBLOCK)
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        _ = launchDirectory.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }

        var spawnAttributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&spawnAttributes)

        var pid: pid_t = 0
        let spawnStatus = spawnProcess(
            pid: &pid,
            fileActions: &fileActions,
            attributes: &spawnAttributes
        )

        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttributes)
        close(slave)

        guard spawnStatus == 0 else {
            close(master)
            throw SessionError.couldNotOpenPseudoTerminal(String(cString: strerror(spawnStatus)))
        }

        processID = pid
        masterDescriptor = master

        configureReadLoop()
        monitorExit()
        sendBootstrap()
    }

    func send(_ input: String) throws {
        guard masterDescriptor >= 0 else { return }
        let data = Data(input.utf8)
        let result = data.withUnsafeBytes { buffer -> ssize_t in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return write(masterDescriptor, baseAddress, buffer.count)
        }

        guard result >= 0 else {
            throw SessionError.couldNotWrite
        }
    }

    func interrupt() {
        try? send(String(UnicodeScalar(3)))
    }

    func terminate() {
        guard processID > 0 else {
            cleanup()
            return
        }

        kill(processID, SIGTERM)
        cleanup()
    }

    private func configureReadLoop() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)

            while !self.hasCleanedUp {
                let count = read(self.masterDescriptor, &buffer, buffer.count)

                if count > 0 {
                    let chunk = String(decoding: buffer.prefix(count), as: UTF8.self)
                    DispatchQueue.main.async {
                        self.onOutput?(chunk)
                    }
                    continue
                }

                if count == 0 {
                    DispatchQueue.main.async {
                        self.cleanup()
                    }
                    break
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(50_000)
                    continue
                }

                usleep(50_000)
            }
        }
    }

    private func monitorExit() {
        let pid = processID
        ioQueue.async { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            let waitedPID = waitpid(pid, &status, 0)
            guard waitedPID > 0 else { return }

            let exitCode = self.decodeExitStatus(status)

            DispatchQueue.main.async {
                self.cleanup()
                self.onExit?(exitCode)
            }
        }
    }

    private func sendBootstrap() {
        try? send(Self.bootstrapScript)
    }

    private func cleanup() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true

        if masterDescriptor >= 0 {
            close(masterDescriptor)
            masterDescriptor = -1
        }

        processID = 0
    }

    private func spawnProcess(
        pid: UnsafeMutablePointer<pid_t>,
        fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
        attributes: UnsafeMutablePointer<posix_spawnattr_t?>
    ) -> Int32 {
        var resolvedEnvironment = environment
        resolvedEnvironment["PWD"] = launchDirectory

        let shellPath = "/bin/zsh"
        let shellArguments = ["-f", "-i"]

        var argvStorage: [UnsafeMutablePointer<CChar>?] = shellArguments.map { strdup($0) }
        let shellCString = strdup(shellPath)
        argvStorage.insert(shellCString, at: 0)
        argvStorage.append(nil)

        var envpStorage: [UnsafeMutablePointer<CChar>?] = resolvedEnvironment.map { strdup("\($0.key)=\($0.value)") }
        envpStorage.append(nil)

        let status = argvStorage.withUnsafeMutableBufferPointer { argvBuffer in
            envpStorage.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    pid,
                    shellPath,
                    fileActions,
                    attributes,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }

        argvStorage.forEach { pointer in
            if let pointer {
                Darwin.free(pointer)
            }
        }
        envpStorage.forEach { pointer in
            if let pointer {
                Darwin.free(pointer)
            }
        }

        return status
    }

    private func decodeExitStatus(_ status: Int32) -> Int32 {
        let signalMask = status & 0x7f
        if signalMask == 0 {
            return (status >> 8) & 0xff
        }
        if signalMask != 0x7f {
            return 128 + signalMask
        }
        return -1
    }
}
