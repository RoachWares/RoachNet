import XCTest
@testable import RoachNetCore

final class InstallerConfigSupportTests: XCTestCase {
    func testInstallerScratchPathRecognizesRegressionCheckRoots() {
        XCTAssertTrue(
            RoachNetRepositoryLocator.isInstallerScratchPath("/Users/example/RoachNet.regressioncheck")
        )
        XCTAssertTrue(
            RoachNetRepositoryLocator.isInstallerScratchPath("/tmp/RoachNet.staging-5B63")
        )
        XCTAssertFalse(
            RoachNetRepositoryLocator.isInstallerScratchPath("/Users/example/RoachNet")
        )
    }

    func testSanitizedPersistedConfigResetsScratchInstallRootBackToPublicDefault() {
        let scratchRoot = "/Users/example/RoachNet.regressioncheck"
        let config = RoachNetInstallerConfig(
            installPath: scratchRoot,
            installedAppPath: URL(fileURLWithPath: scratchRoot)
                .appendingPathComponent("app", isDirectory: true)
                .appendingPathComponent("RoachNet.app", isDirectory: true)
                .path,
            storagePath: URL(fileURLWithPath: scratchRoot)
                .appendingPathComponent("storage", isDirectory: true)
                .path,
            installRoachClaw: true,
            setupCompletedAt: "2026-04-20T00:00:00Z",
            bootstrapPending: true,
            bootstrapFailureCount: 2,
            lastRuntimeHealthAt: "2026-04-20T00:05:00Z",
            pendingLaunchIntro: true,
            pendingRoachClawSetup: true
        )

        let sanitized = RoachNetRepositoryLocator.sanitizedPersistedConfig(config)
        let expectedInstallPath = RoachNetRepositoryLocator.defaultInstallPath()

        XCTAssertEqual(sanitized.installPath, expectedInstallPath)
        XCTAssertEqual(
            sanitized.installedAppPath,
            RoachNetRepositoryLocator.defaultInstalledAppPath(installPath: expectedInstallPath)
        )
        XCTAssertEqual(
            sanitized.storagePath,
            RoachNetRepositoryLocator.defaultStoragePath(installPath: expectedInstallPath)
        )
        XCTAssertNil(sanitized.setupCompletedAt)
        XCTAssertFalse(sanitized.bootstrapPending)
        XCTAssertEqual(sanitized.bootstrapFailureCount, 0)
        XCTAssertNil(sanitized.lastRuntimeHealthAt)
        XCTAssertFalse(sanitized.pendingLaunchIntro)
        XCTAssertFalse(sanitized.pendingRoachClawSetup)
    }

    func testSanitizedPersistedConfigKeepsCustomInstallRoot() {
        let customRoot = "/Users/example/Applications/RoachNet"
        let config = RoachNetInstallerConfig(
            installPath: customRoot,
            installedAppPath: URL(fileURLWithPath: customRoot)
                .appendingPathComponent("app", isDirectory: true)
                .appendingPathComponent("RoachNet.app", isDirectory: true)
                .path,
            storagePath: URL(fileURLWithPath: customRoot)
                .appendingPathComponent("storage", isDirectory: true)
                .path,
            installRoachClaw: false
        )

        let sanitized = RoachNetRepositoryLocator.sanitizedPersistedConfig(config)

        XCTAssertEqual(sanitized.installPath, customRoot)
        XCTAssertEqual(sanitized.installedAppPath, config.installedAppPath)
        XCTAssertEqual(sanitized.storagePath, config.storagePath)
        XCTAssertFalse(sanitized.installRoachClaw)
    }
}
