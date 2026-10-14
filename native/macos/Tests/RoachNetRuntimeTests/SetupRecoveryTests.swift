import XCTest
@testable import RoachNetRuntime

/// ROA-94: an upgrade cut off after the old install was moved aside comes
/// back when Setup runs again, the DMG way and the Homebrew way. On a Mac the
/// 1.1.0 and 1.1.1 installers left the person's install in the backup in both
/// cases: a log line (or the cask's Setup app) had recreated the install root
/// first, so recovery found a root and kept the backup instead.
final class SetupRecoveryTests: XCTestCase {
    private var parent = ""

    override func setUpWithError() throws {
        parent = NSTemporaryDirectory() + "roachnet-setup-recovery-" + JS.randomHex(6)
        try Files.mkdirp(parent)
    }

    override func tearDownWithError() throws {
        _ = Processes.run("/bin/rm", ["-rf", parent])
    }

    private var root: String { Path.join(parent, "RoachNet") }
    private var engine: SetupEngine { SetupEngine(environment: ["HOME": parent]) }

    /// A finished install of RoachNet with a person's note, moved aside as an upgrade does.
    private func installMovedAside(stamp: Int64 = 1_760_000_000_000, setupMarker: String = "older setup") throws -> String {
        let backup = Path.join(parent, "RoachNet.backup-\(stamp)")
        try Files.mkdirp(Path.join(backup, "app", "RoachNet.app", "Contents"))
        try Files.write("app", to: Path.join(backup, "app", "RoachNet.app", "Contents", "marker"))
        try Files.write("{\"schema\":\"org.roachnet.install.v1\",\"version\":\"1.1.0\"}", to: Path.join(backup, SetupEngine.installManifestName))
        try Files.mkdirp(Path.join(backup, "storage", "Vault", "notes"))
        try Files.write("the person's note", to: Path.join(backup, "storage", "Vault", "notes", "keep.md"))
        try Files.mkdirp(Path.join(backup, "storage", "logs"))
        try Files.write("[old] runtime log\n", to: Path.join(backup, "storage", "logs", "roachnet-native-api.log"))
        try Files.mkdirp(Path.join(backup, "setup", "RoachNet Setup.app"))
        try Files.write(setupMarker, to: Path.join(backup, "setup", "RoachNet Setup.app", "marker"))
        return backup
    }

    /// The DMG way, with the staging folder the cut-off run left beside it.
    func testAnInstallMovedAsideComesBackWhenItsStagingFolderWasLeft() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(parent, "RoachNet.staging-0123abcd", "app"))
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note")
        XCTAssertFalse(Files.exists(backup))
        XCTAssertFalse(Files.exists(Path.join(parent, "RoachNet.staging-0123abcd")))
    }

    /// The root holds only what Setup (or the cask) writes before an install:
    /// the cask's newer Setup app and an older Setup's log lines. The install
    /// comes back, with the cask's Setup app and those log lines kept.
    func testAnInstallComesBackOverARootHoldingOnlySetupFiles() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup", "RoachNet Setup.app"))
        try Files.write("newer setup", to: Path.join(root, "setup", "RoachNet Setup.app", "marker"))
        try Files.mkdirp(Path.join(root, "storage", "logs"))
        try Files.write("[now] setup: Phase: Inspecting system\n", to: Path.join(root, "storage", "logs", "roachnet-native-api.log"))
        XCTAssertTrue(engine.holdsOnlySetupFiles(root))
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note", "the install is back")
        XCTAssertEqual(Files.readText(Path.join(root, "setup", "RoachNet Setup.app", "marker")), "newer setup", "the cask's Setup app is kept")
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "logs", "roachnet-native-api.log")), "[old] runtime log\n", "the install's own log is back")
        let kept = Files.entries(Path.join(root, "storage", "logs")).map(\.name).filter { $0.hasPrefix("roachnet-native-api.log.before-recovery-") }
        XCTAssertEqual(kept.count, 1, "Setup's earlier log lines are kept")
        XCTAssertFalse(Files.exists(backup))
        XCTAssertFalse(Files.entries(parent).contains { $0.name.hasPrefix("RoachNet.setup-files-") }, "nothing is left beside the install")
    }

    /// Once the install is back, a Setup file that can't be moved doesn't turn
    /// the recovery into a failure: it stays beside the install, and the log
    /// says where.
    func testAnInstallStaysRestoredWhenASetupFileCannotBeMoved() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup", "RoachNet Setup.app"))
        try Files.write("newer setup", to: Path.join(root, "setup", "RoachNet Setup.app", "marker"))
        // No room for the ".before-recovery-<time>" suffix: names stop at 255 bytes.
        let long = String(repeating: "l", count: 240) + ".log"
        try Files.mkdirp(Path.join(root, "storage", "logs"))
        try Files.write("[now] setup line\n", to: Path.join(root, "storage", "logs", long))
        let engine = self.engine
        var lines: [String] = []
        engine.onLog = { lines.append($0) }
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note")
        XCTAssertEqual(Files.readText(Path.join(root, "setup", "RoachNet Setup.app", "marker")), "newer setup")
        XCTAssertFalse(Files.exists(backup))
        XCTAssertTrue(lines.contains { $0.contains("Restored the previous install") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("could not be restored") }, "\(lines)")
        let aside = Files.entries(parent).map(\.name).filter { $0.hasPrefix("RoachNet.setup-files-") }
        XCTAssertEqual(aside.count, 1, "the log that couldn't move stays beside the install")
        if let folder = aside.first {
            XCTAssertTrue(Files.exists(Path.join(parent, folder, "storage", "logs", long)))
            XCTAssertTrue(lines.contains { $0.contains(folder) }, "the log names where it is: \(lines)")
        }
    }

    /// A root that holds an install, or anything else a person put there, is
    /// left alone, and so is the backup.
    func testARootWithAnInstallOrOtherFilesIsLeftAlone() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup"))
        try Files.write("mine", to: Path.join(root, "my-notes.txt"))
        XCTAssertFalse(engine.holdsOnlySetupFiles(root))
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "my-notes.txt")), "mine")
        XCTAssertTrue(Files.exists(backup), "the backup is kept")

        Files.remove(Path.join(root, "my-notes.txt"))
        try Files.write("{}", to: Path.join(root, SetupEngine.installManifestName))
        XCTAssertFalse(engine.holdsOnlySetupFiles(root), "a root with an install manifest holds an install")
        try Files.mkdirp(Path.join(root, "storage", "logs", "nested"))
        Files.remove(Path.join(root, SetupEngine.installManifestName))
        XCTAssertFalse(engine.holdsOnlySetupFiles(root), "a folder inside storage/logs isn't Setup's")
    }

    private struct InjectedFailure: Error {}

    /// A restore interrupted part-way (the cross-device copy fallback can leave a
    /// partial root) keeps the person's data in the backup and leaves a setup-only
    /// root, so a later run restores the install rather than leaving it half-done.
    func testARestoreInterruptedPartWayKeepsTheDataAndRetries() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup", "RoachNet Setup.app"))
        try Files.write("newer setup", to: Path.join(root, "setup", "RoachNet Setup.app", "marker"))
        let engine = self.engine
        engine.moveIntoPlace = { source, destination in
            if Path.basename(source).hasPrefix("RoachNet.backup-") {
                // Some of the backup reached the root, then the move failed.
                try Files.mkdirp(Path.join(destination, "storage", "Vault", "notes"))
                try Files.write("half", to: Path.join(destination, "storage", "Vault", "notes", "keep.md"))
                throw InjectedFailure()
            }
            try SetupPlatform.moveItem(source, destination)
        }
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(backup, "storage", "Vault", "notes", "keep.md")), "the person's note", "the data is preserved in the backup")
        XCTAssertTrue(self.engine.holdsOnlySetupFiles(root), "the root is left setup-only, so it can be retried")
        // The next run, uninterrupted, restores the install.
        self.engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note", "the retry restored the install")
        XCTAssertFalse(Files.exists(backup))
    }

    /// If the root can't even be moved aside, recovery changes nothing: the
    /// setup-only root and the backup are both left in place and a later run can
    /// still restore the install.
    func testARestoreThatCannotMoveTheRootAsideLeavesEverythingSafe() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup"))
        let engine = self.engine
        engine.moveIntoPlace = { source, destination in
            if Path.basename(destination).hasPrefix("RoachNet.setup-files-") { throw InjectedFailure() }
            try SetupPlatform.moveItem(source, destination)
        }
        var lines: [String] = []
        engine.onLog = { lines.append($0) }
        engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertTrue(Files.isDirectory(Path.join(root, "setup")), "the setup-only root is untouched")
        XCTAssertTrue(Files.exists(backup), "the backup is kept")
        XCTAssertTrue(lines.contains { $0.contains("could not be restored") }, "\(lines)")
        self.engine.recoverInterruptedInstall(finalRoot: root)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note", "a later run restores it")
        XCTAssertFalse(Files.exists(backup))
    }
}

/// ROA-94: Setup's own log stays outside every install root, so a log line
/// can't recreate a root an interrupted upgrade moved aside.
final class SetupLogPlacementTests: XCTestCase {
    func testSetupLogsBesideTheInstallerConfig() throws {
        let home = NSTemporaryDirectory() + "roachnet-setup-log-" + JS.randomHex(6)
        defer { RuntimeLog.redirect(to: nil); _ = Processes.run("/bin/rm", ["-rf", home]) }
        let engine = SetupEngine(environment: ["HOME": home])
        XCTAssertEqual(Path.dirname(engine.setupLogPath), Path.dirname(engine.configPath))
        XCTAssertFalse(engine.setupLogPath.hasPrefix(engine.defaultInstallPath() + "/"))
        RuntimeLog.redirect(to: engine.setupLogPath)
        engine.log("probe line")
        XCTAssertTrue(Files.readText(engine.setupLogPath)?.contains("setup: probe line") == true)
        XCTAssertFalse(Files.exists(engine.defaultInstallPath()), "logging made no install root")
        let explicit = SetupEngine(environment: ["HOME": home, "ROACHNET_INSTALLER_CONFIG_PATH": Path.join(home, "cfg", "installer.json")])
        XCTAssertEqual(explicit.setupLogPath, Path.join(home, "cfg", "setup.log"))
    }
}
