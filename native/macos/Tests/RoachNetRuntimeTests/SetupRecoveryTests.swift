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
    /// partial root) keeps the person's data in the backup, moves the partial
    /// root aside without deleting it, and leaves a setup-only root, so a later
    /// run restores the install rather than leaving it half-done.
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
        let partial = Files.entries(parent).map(\.name).filter { $0.hasPrefix("RoachNet.partial-restore-") }
        XCTAssertEqual(partial.count, 1, "the partial root is moved aside, not deleted")
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

    /// An engine whose install would stop at the free-space check if it ever
    /// got past recovery, so these tests never stage or install anything.
    private func blockedEngine() -> SetupEngine {
        SetupEngine(environment: [
            "HOME": parent,
            "ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST": "1",
            "ROACHNET_SETUP_TEST_MIN_FREE_BYTES": String(Int64.max),
        ])
    }

    private var installRequest: JSON { ["installPath": JSON(root), "installRoachClaw": false, "autoLaunch": false] }

    /// Another Setup run (a 1.1.0 Setup takes no run lock) can put the backup
    /// back between this run's two moves. The root is then that install: it is
    /// left alone, and this run's Setup files are kept beside it, not deleted.
    func testARestoreThatLostItsBackupToAnotherRunLeavesTheRootAlone() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup", "RoachNet Setup.app"))
        try Files.write("newer setup", to: Path.join(root, "setup", "RoachNet Setup.app", "marker"))
        let engine = self.engine
        engine.moveIntoPlace = { source, destination in
            if Path.basename(source).hasPrefix("RoachNet.backup-") {
                // The other run found no root and put the backup back first,
                // so this run's move fails.
                try SetupPlatform.moveItem(source, destination)
                throw InjectedFailure()
            }
            try SetupPlatform.moveItem(source, destination)
        }
        let outcome = engine.recoverInterruptedInstall(finalRoot: root)
        guard case .restoreFailed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the person's note", "the install the other run put back is untouched")
        XCTAssertFalse(Files.exists(backup))
        let aside = Files.entries(parent).map(\.name).filter { $0.hasPrefix("RoachNet.setup-files-") }
        XCTAssertEqual(aside.count, 1, "this run's Setup files are kept")
        if let folder = aside.first {
            XCTAssertEqual(Files.readText(Path.join(parent, folder, "setup", "RoachNet Setup.app", "marker")), "newer setup")
        }
    }

    /// A backup that should have been put back and wasn't stops the install
    /// before anything is staged, so RoachNet doesn't open empty while the
    /// person's data sits in the backup.
    func testAFailedRestoreStopsTheInstall() throws {
        let backup = try installMovedAside()
        try Files.mkdirp(Path.join(root, "setup", "RoachNet Setup.app"))
        let engine = blockedEngine()
        RuntimeLog.redirect(to: engine.setupLogPath)
        defer { RuntimeLog.redirect(to: nil) }
        engine.moveIntoPlace = { source, destination in
            if Path.basename(source).hasPrefix("RoachNet.backup-") { throw InjectedFailure() }
            try SetupPlatform.moveItem(source, destination)
        }
        let task = try engine.installSynchronously(installRequest)
        XCTAssertEqual(task["status"].stringValue, "failed")
        XCTAssertTrue(task["error"].jsString.contains("could not put back"), task["error"].jsString)
        XCTAssertEqual(Files.readText(Path.join(backup, "storage", "Vault", "notes", "keep.md")), "the person's note")
        XCTAssertTrue(engine.holdsOnlySetupFiles(root), "the root is as it was")
        XCTAssertEqual(Files.entries(parent).map(\.name).filter { $0.hasPrefix("RoachNet.") }, [Path.basename(backup)], "nothing was staged or moved aside")
    }

    /// A folder the person named like a backup isn't Setup's, so it is never
    /// moved into the install's place.
    func testOnlySetupsOwnBackupsAreRestored() throws {
        let own = Path.join(parent, "RoachNet.backup-before-1.1")
        try Files.mkdirp(Path.join(own, "storage", "Vault"))
        try Files.write("kept by hand", to: Path.join(own, "storage", "Vault", "mine.md"))
        XCTAssertEqual(engine.recoverInterruptedInstall(finalRoot: root), .noBackup)
        XCTAssertFalse(Files.exists(root))
        XCTAssertEqual(Files.readText(Path.join(own, "storage", "Vault", "mine.md")), "kept by hand")
    }

    /// The backup put back is the newest one holding more than Setup's own
    /// files: a run cut off twice can leave a newer one holding only those.
    func testTheNewestBackupThatHoldsAnInstallIsRestored() throws {
        let older = try installMovedAside(stamp: 1_760_000_000_000)
        let newer = try installMovedAside(stamp: 1_760_000_100_000)
        try Files.write("the newer note", to: Path.join(newer, "storage", "Vault", "notes", "keep.md"))
        let shell = Path.join(parent, "RoachNet.backup-1760000200000")
        try Files.mkdirp(Path.join(shell, "setup", "RoachNet Setup.app"))
        try Files.mkdirp(Path.join(shell, "storage", "logs"))
        try Files.write("[then] setup line\n", to: Path.join(shell, "storage", "logs", "roachnet-native-api.log"))
        // An earlier time with fewer digits, which sorts last as text.
        let oldest = try installMovedAside(stamp: 999)
        XCTAssertEqual(engine.recoverInterruptedInstall(finalRoot: root), .restored)
        XCTAssertEqual(Files.readText(Path.join(root, "storage", "Vault", "notes", "keep.md")), "the newer note")
        XCTAssertFalse(Files.exists(newer))
        XCTAssertTrue(Files.exists(older), "older backups are kept")
        XCTAssertTrue(Files.exists(oldest))
        XCTAssertTrue(Files.isDirectory(shell), "the backup holding only Setup's files is kept")
    }

    /// A root, or a folder in it, that can't be read may hold anything: it is
    /// never taken for Setup's files, and never counted as empty.
    func testAnUnreadableRootIsNotTakenForSetupFiles() throws {
        try XCTSkipIf(getuid() == 0, "root can read any folder")
        let backup = try installMovedAside()
        let storage = Path.join(root, "storage")
        let logs = Path.join(storage, "logs")
        try Files.mkdirp(logs)
        try Files.write("[now] setup line\n", to: Path.join(logs, "roachnet-native-api.log"))
        XCTAssertTrue(engine.holdsOnlySetupFiles(root))
        defer {
            chmod(logs, 0o755)
            chmod(storage, 0o755)
        }
        chmod(logs, 0)
        XCTAssertFalse(engine.holdsOnlySetupFiles(root))
        XCTAssertFalse(engine.holdsNothing(storage))
        XCTAssertEqual(engine.recoverInterruptedInstall(finalRoot: root), .keptBackups)
        XCTAssertTrue(Files.exists(backup), "the backup is kept")
        XCTAssertFalse(Files.entries(parent).contains { $0.name.hasPrefix("RoachNet.setup-files-") }, "the root wasn't moved")
        chmod(logs, 0o755)
        chmod(storage, 0)
        XCTAssertFalse(engine.holdsOnlySetupFiles(root), "nor when storage can't be read")
        chmod(storage, 0o755)
        XCTAssertEqual(Files.readText(Path.join(logs, "roachnet-native-api.log")), "[now] setup line\n", "the root is untouched")
    }

    /// Two Setup runs (the Setup app and Homebrew's `--install`, say) never
    /// move the same install at once: the second stops before it looks at the
    /// install, and says why.
    func testTwoSetupRunsCannotOverlap() throws {
        let backup = try installMovedAside()
        let engine = blockedEngine()
        RuntimeLog.redirect(to: engine.setupLogPath)
        defer { RuntimeLog.redirect(to: nil) }
        do {
            let first = try SetupRunLock(path: engine.setupLockPath)
            defer { withExtendedLifetime(first) {} }
            XCTAssertThrowsError(try SetupRunLock(path: engine.setupLockPath)) { error in
                XCTAssertTrue("\(error)".contains("Another RoachNet Setup is running"), "\(error)")
            }
            let task = try engine.installSynchronously(installRequest)
            XCTAssertEqual(task["status"].stringValue, "failed")
            XCTAssertTrue(task["error"].jsString.contains("Another RoachNet Setup is running"), task["error"].jsString)
            XCTAssertTrue(Files.exists(backup), "the second run left the backup alone")
            XCTAssertFalse(Files.exists(root))
        }
        XCTAssertNoThrow(try SetupRunLock(path: engine.setupLockPath), "the lock is free once the first run is over")
        XCTAssertEqual(engine.recoverInterruptedInstall(finalRoot: root), .restored, "and the next run goes ahead")
    }

    /// Only Setup's own unfinished staging folders are removed: not a folder
    /// or file the person named alike, and not a link.
    func testOnlySetupsOwnStagingFoldersAreRemoved() throws {
        try Files.mkdirp(Path.join(parent, "RoachNet.staging-0123abcd", "app"))
        try Files.mkdirp(Path.join(parent, "RoachNet.staging-site"))
        try Files.write("mine", to: Path.join(parent, "RoachNet.staging-site", "index.html"))
        try Files.write("a file", to: Path.join(parent, "RoachNet.staging-89abcdef"))
        let elsewhere = Path.join(parent, "elsewhere")
        try Files.mkdirp(elsewhere)
        try Files.write("linked", to: Path.join(elsewhere, "keep.txt"))
        try FileManager.default.createSymbolicLink(atPath: Path.join(parent, "RoachNet.staging-fedcba98"), withDestinationPath: elsewhere)
        XCTAssertEqual(engine.recoverInterruptedInstall(finalRoot: root), .noBackup)
        XCTAssertFalse(Files.exists(Path.join(parent, "RoachNet.staging-0123abcd")), "Setup's own staging folder is removed")
        XCTAssertEqual(Files.readText(Path.join(parent, "RoachNet.staging-site", "index.html")), "mine")
        XCTAssertEqual(Files.readText(Path.join(parent, "RoachNet.staging-89abcdef")), "a file")
        XCTAssertNotNil(Files.lstatInfo(Path.join(parent, "RoachNet.staging-fedcba98")), "the link is kept")
        XCTAssertEqual(Files.readText(Path.join(elsewhere, "keep.txt")), "linked")
    }

    /// Setup's folders are told apart by their exact names, compared as the
    /// file system compares names.
    func testOnlySetupsOwnFolderNamesMatch() {
        func matches(_ name: String, _ kind: SetupEngine.SetupSiblingKind, ignoringCase: Bool = false) -> Bool {
            SetupEngine.isSetupSibling(name, base: "RoachNet", kind: kind, ignoringCase: ignoringCase)
        }
        XCTAssertTrue(matches("RoachNet.staging-0123abcd", .staging))
        XCTAssertFalse(matches("RoachNet.staging-site", .staging))
        XCTAssertFalse(matches("RoachNet.staging-0123abcde", .staging))
        XCTAssertFalse(matches("RoachNet.staging-0123abc", .staging))
        XCTAssertFalse(matches("RoachNet.staging-0123ABCD", .staging), "Setup writes lowercase hex")
        XCTAssertFalse(matches("RoachNet.staging-", .staging))
        XCTAssertFalse(matches("RoachNet.staging-0123abcd.old", .staging))
        XCTAssertFalse(matches("RoachNetX.staging-0123abcd", .staging))
        XCTAssertFalse(matches("RoachNet.backup-01234567", .staging))
        XCTAssertTrue(matches("RoachNet.backup-1760000000000", .backup))
        XCTAssertTrue(matches("RoachNet.backup-7", .backup))
        XCTAssertFalse(matches("RoachNet.backup-before-1.1", .backup))
        XCTAssertFalse(matches("RoachNet.backup-", .backup))
        XCTAssertFalse(matches("RoachNet.backup--5", .backup))
        XCTAssertFalse(matches("RoachNet.backup-12345678901234567890", .backup), "longer than any time Setup writes")
        XCTAssertFalse(matches("RoachNet.backup-\u{0661}\u{0662}", .backup), "only ASCII digits")
        XCTAssertFalse(matches("My RoachNet.backup-1760000000000", .backup))
        XCTAssertFalse(matches("RoachNet.staging-0123abcd", .backup))
        #if canImport(Darwin)
        XCTAssertTrue(matches("roachnet.Staging-0123abcd", .staging, ignoringCase: true), "a volume that ignores case")
        XCTAssertFalse(matches("roachnet.Staging-0123abcd", .staging, ignoringCase: false), "a case-sensitive volume")
        XCTAssertTrue(SetupEngine.isSetupSibling("Cafe\u{301}.backup-5", base: "Caf\u{E9}", kind: .backup, ignoringCase: false), "macOS takes both Unicode forms as one name")
        #else
        XCTAssertFalse(matches("roachnet.Staging-0123abcd", .staging, ignoringCase: true))
        XCTAssertFalse(SetupEngine.isSetupSibling("Cafe\u{301}.backup-5", base: "Caf\u{E9}", kind: .backup, ignoringCase: false), "Linux keeps the two forms apart")
        #endif
    }

    /// Whether names ignore case is the volume's own answer.
    func testNamesIgnoreCaseFollowsTheVolume() throws {
        try Files.write("probe", to: Path.join(parent, "case-probe"))
        XCTAssertEqual(SetupPlatform.namesIgnoreCase(in: parent), Files.exists(Path.join(parent, "CASE-PROBE")))
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
