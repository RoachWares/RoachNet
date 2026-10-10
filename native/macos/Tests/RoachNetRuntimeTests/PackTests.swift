import XCTest
@testable import RoachNetRuntime

final class PackTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "roachnet-pack-tests-" + JS.randomHex(6)
        try Files.mkdirp(root)
    }

    override func tearDownWithError() throws {
        Files.remove(root)
    }

    private func registry(bundled: [PackManifest] = PackCatalog.bundledCapabilityPacks, appVersion: String = "1.1.0") -> PackRegistry {
        PackRegistry(storageRoot: root, appVersion: appVersion, platform: "macos", bundledPacks: bundled)
    }

    private func writePackage(_ manifest: PackManifest, files: [String: Data], at directory: String) throws {
        try Files.mkdirp(directory)
        try Files.write(try manifest.encoded(), to: Path.join(directory, "manifest.json"))
        for (name, data) in files {
            try Files.mkdirp(Path.dirname(Path.join(directory, name)))
            try data.write(to: URL(fileURLWithPath: Path.join(directory, name)))
        }
    }

    private func resourcePack(id: String = "voice-test", version: String = "1.0.0", payload: Data, dependencies: [PackDependency] = []) -> (PackManifest, [String: Data]) {
        let manifest = PackManifest(
            id: id, version: version, kind: .resource, name: "Test pack \(id)",
            requires: PackRequirements(roachnet: "1.1.0"),
            dependencies: dependencies,
            resources: [PackResource(path: "model/weights.bin", sha256: SHA256Digest.hex(payload), bytes: payload.count)],
            dataRoots: [PackDataRoot(path: "RoachSpeech/voices/\(id)", description: "Recorded samples")]
        )
        return (manifest, ["model/weights.bin": payload])
    }

    // MARK: Manifest

    func testManifestRoundTripAndValidation() throws {
        let (manifest, _) = resourcePack(payload: Data("abc".utf8))
        let decoded = try PackManifest.decode(try manifest.encoded())
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.downloadBytes, 3)
    }

    func testManifestRejectsTraversalBadDigestsAndPlainHttp() throws {
        var bad = resourcePack(payload: Data("abc".utf8)).0
        bad.resources[0].path = "../escape.bin"
        XCTAssertThrowsError(try bad.validate()) { XCTAssertTrue("\($0)".contains("escapes")) }
        bad = resourcePack(payload: Data("abc".utf8)).0
        bad.resources[0].sha256 = "nope"
        XCTAssertThrowsError(try bad.validate())
        bad = resourcePack(payload: Data("abc".utf8)).0
        bad.resources[0].url = "http://example.com/weights.bin"
        XCTAssertThrowsError(try bad.validate()) { XCTAssertTrue("\($0)".contains("https")) }
        bad = resourcePack(payload: Data("abc".utf8)).0
        bad.id = "Bad ID"
        XCTAssertThrowsError(try bad.validate())
        var capability = PackCatalog.bundledCapabilityPacks[0]
        capability.resources = [PackResource(path: "x", sha256: String(repeating: "a", count: 64), bytes: 1)]
        XCTAssertThrowsError(try capability.validate()) { XCTAssertTrue("\($0)".contains("Capability")) }
    }

    func testSemanticVersionOrdering() {
        XCTAssertTrue(SemanticVersion("1.0.6")! < SemanticVersion("1.1.0")!)
        XCTAssertTrue(SemanticVersion("1.1.0-beta.1")! < SemanticVersion("1.1.0")!)
        XCTAssertNil(SemanticVersion("1.1"))
        XCTAssertEqual(SemanticVersion("v2.0.0")?.description, "2.0.0")
    }

    func testBundledCatalogIsValidAndAcyclic() throws {
        for manifest in PackCatalog.bundledCapabilityPacks { try manifest.validate() }
        let registry = registry()
        for manifest in PackCatalog.bundledCapabilityPacks {
            XCTAssertNoThrow(try registry.resolveDependencies(of: manifest.id), manifest.id)
        }
        XCTAssertEqual(try registry.resolveDependencies(of: "org").map(\.id), ["roachclaw"])
    }

    // MARK: Registry state

    func testFreshRegistryEnablesEveryBundledPackAndPersists() throws {
        let registry = registry()
        let records = registry.records()
        XCTAssertEqual(records.count, PackCatalog.bundledCapabilityPacks.count)
        XCTAssertTrue(records.allSatisfy(\.isEnabled))
        XCTAssertTrue(Files.exists(Path.join(root, "packs", "state.json")))
        let again = self.registry()
        XCTAssertTrue(again.record("org")!.isEnabled)
    }

    func testDisableRefusesWhileDependentsAreOnAndEnableTurnsDependenciesOn() throws {
        let registry = registry()
        XCTAssertThrowsError(try registry.disable("roachclaw")) { error in
            XCTAssertTrue("\(error)".contains("Org") || "\(error)".contains("Dev"), "\(error)")
        }
        _ = try registry.disable("org")
        _ = try registry.disable("dev")
        _ = try registry.disable("speech")
        _ = try registry.disable("roachclaw")
        XCTAssertFalse(registry.record("roachclaw")!.isEnabled)
        _ = try registry.enable("org")
        XCTAssertTrue(registry.record("roachclaw")!.isEnabled, "enabling Org turns RoachClaw back on")
        XCTAssertTrue(registry.record("org")!.isEnabled)
    }

    func testDependencyResolutionReportsMissingOldAndCyclic() throws {
        let a = PackManifest(id: "a", version: "1.0.0", kind: .capability, name: "A", dependencies: [PackDependency(id: "b")])
        let b = PackManifest(id: "b", version: "1.0.0", kind: .capability, name: "B", dependencies: [PackDependency(id: "a")])
        let registry = registry(bundled: [a, b])
        XCTAssertThrowsError(try registry.resolveDependencies(of: "a")) { XCTAssertTrue("\($0)".contains("cycle")) }
        let needsNew = PackManifest(id: "c", version: "1.0.0", kind: .capability, name: "C", dependencies: [PackDependency(id: "roachclaw", minimumVersion: "9.0.0")])
        XCTAssertThrowsError(try self.registry(bundled: PackCatalog.bundledCapabilityPacks + [needsNew]).resolveDependencies(of: "c")) {
            XCTAssertTrue("\($0)".contains("9.0.0"))
        }
        let orphan = PackManifest(id: "d", version: "1.0.0", kind: .capability, name: "D", dependencies: [PackDependency(id: "nothing")])
        XCTAssertThrowsError(try self.registry(bundled: [orphan]).resolveDependencies(of: "d")) { XCTAssertTrue("\($0)".contains("not installed")) }
    }

    func testCompatibilityGate() throws {
        let old = registry(appVersion: "1.0.6")
        let (manifest, _) = resourcePack(payload: Data("abc".utf8))
        XCTAssertThrowsError(try old.checkCompatibility(manifest)) { XCTAssertTrue("\($0)".contains("1.1.0")) }
        var other = manifest
        other.requires.platforms = ["ios"]
        XCTAssertThrowsError(try registry().checkCompatibility(other))
    }

    // MARK: Install transaction

    func testLocalPackageInstallsVerifiesAndWritesReceipt() throws {
        let payload = Data("weights".utf8)
        let (manifest, files) = resourcePack(payload: payload)
        let package = Path.join(root, "package")
        try writePackage(manifest, files: files, at: package)
        let registry = registry()
        let record = try PackInstaller(registry: registry).installLocalPackage(at: package)
        XCTAssertTrue(record.isInstalled && record.isEnabled)
        let installed = registry.installRoot(for: "voice-test", version: "1.0.0")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: Path.join(installed, "model", "weights.bin"))), payload)
        let receipt = try JSON.parse(try String(contentsOfFile: Path.join(installed, "receipt.json"), encoding: .utf8))
        XCTAssertEqual(receipt["files"].array.first?["sha256"].stringValue, SHA256Digest.hex(payload))
        XCTAssertEqual(Files.entries(registry.stagingRoot).count, 0, "staging is empty after a commit")
        let listed = registry.catalogJSON(includeSizes: true)["packs"].array.first { $0["id"].stringValue == "voice-test" }
        XCTAssertEqual(listed?["installed"].truthy, true)
        XCTAssertEqual(listed?["installedBytes"].jsString, String(Files.directorySize(installed)))
    }

    func testTamperedPackageRollsBackAndKeepsPreviousVersion() throws {
        let good = Data("good".utf8)
        let (v1, files) = resourcePack(payload: good)
        try writePackage(v1, files: files, at: Path.join(root, "v1"))
        let registry = registry()
        let installer = PackInstaller(registry: registry)
        _ = try installer.installLocalPackage(at: Path.join(root, "v1"))

        var v2 = resourcePack(version: "1.1.0", payload: Data("new".utf8)).0
        v2.resources[0].sha256 = SHA256Digest.hex(Data("something else".utf8)) // digest does not match the bytes
        try writePackage(v2, files: ["model/weights.bin": Data("new".utf8)], at: Path.join(root, "v2"))
        XCTAssertThrowsError(try installer.installLocalPackage(at: Path.join(root, "v2"))) { XCTAssertTrue("\($0)".contains("digest")) }

        XCTAssertEqual(registry.record("voice-test")?.state?.installedVersion, "1.0.0", "the previous version stays current")
        XCTAssertTrue(Files.exists(registry.installRoot(for: "voice-test", version: "1.0.0")))
        XCTAssertFalse(Files.exists(registry.installRoot(for: "voice-test", version: "1.1.0")))
        XCTAssertEqual(Files.entries(registry.stagingRoot).count, 0, "no staging folder is left behind")
    }

    func testUpgradeReplacesPreviousVersionAtomically() throws {
        let registry = registry()
        let installer = PackInstaller(registry: registry)
        let (v1, f1) = resourcePack(payload: Data("one".utf8))
        try writePackage(v1, files: f1, at: Path.join(root, "v1"))
        _ = try installer.installLocalPackage(at: Path.join(root, "v1"))
        let (v2, f2) = resourcePack(version: "2.0.0", payload: Data("two".utf8))
        try writePackage(v2, files: f2, at: Path.join(root, "v2"))
        _ = try installer.installLocalPackage(at: Path.join(root, "v2"))
        XCTAssertEqual(registry.record("voice-test")?.state?.installedVersion, "2.0.0")
        XCTAssertFalse(Files.exists(registry.installRoot(for: "voice-test", version: "1.0.0")), "old version removed after the new one is live")
    }

    func testInterruptedInstallLeavesStagingThatTheNextStartSweeps() throws {
        let registry = registry()
        let stale = Path.join(registry.stagingRoot, "voice-test-1.0.0-deadbeef")
        try Files.mkdirp(stale)
        try Files.write("partial", to: Path.join(stale, "model.bin"))
        let swept = PackInstaller(registry: registry).sweepStaleStaging()
        XCTAssertEqual(swept, [stale])
        XCTAssertFalse(Files.exists(stale))
    }

    func testUninstallKeepsDataByDefaultAndRetiresItOnRequest() throws {
        let registry = registry()
        let installer = PackInstaller(registry: registry)
        let (manifest, files) = resourcePack(payload: Data("v".utf8))
        try writePackage(manifest, files: files, at: Path.join(root, "pkg"))
        _ = try installer.installLocalPackage(at: Path.join(root, "pkg"))
        let dataRoot = Path.join(root, "RoachSpeech", "voices", "voice-test")
        try Files.mkdirp(dataRoot)
        try Files.write("my recording", to: Path.join(dataRoot, "sample.wav"))

        let kept = try registry.uninstall("voice-test")
        XCTAssertEqual(kept.retainedDataRoots, [dataRoot])
        XCTAssertTrue(Files.exists(Path.join(dataRoot, "sample.wav")), "user data survives an uninstall")
        XCTAssertFalse(Files.exists(Path.join(registry.installedRoot, "voice-test")))
        XCTAssertNil(registry.record("voice-test"))

        _ = try installer.installLocalPackage(at: Path.join(root, "pkg"))
        let retired = try registry.uninstall("voice-test", retainData: false)
        XCTAssertFalse(Files.exists(dataRoot))
        XCTAssertEqual(retired.retiredDataRoots.count, 1)
        XCTAssertTrue(Files.exists(Path.join(retired.retiredDataRoots[0], "sample.wav")), "deleted data is parked under retired/, not destroyed")
    }

    func testUninstallRefusesWhileDependentsAreEnabled() throws {
        let registry = registry()
        let installer = PackInstaller(registry: registry)
        let (base, f1) = resourcePack(id: "base-pack", payload: Data("b".utf8))
        try writePackage(base, files: f1, at: Path.join(root, "base"))
        _ = try installer.installLocalPackage(at: Path.join(root, "base"))
        let (child, f2) = resourcePack(id: "child-pack", payload: Data("c".utf8), dependencies: [PackDependency(id: "base-pack")])
        try writePackage(child, files: f2, at: Path.join(root, "child"))
        _ = try installer.installLocalPackage(at: Path.join(root, "child"))
        XCTAssertThrowsError(try registry.uninstall("base-pack")) { XCTAssertTrue("\($0)".contains("child")) }
        _ = try registry.disable("child-pack")
        XCTAssertNoThrow(try registry.uninstall("base-pack"))
    }

    func testCapabilityPacksCannotBeInstalledFromPackagesOrUninstalled() throws {
        let registry = registry()
        let manifest = PackCatalog.bundledCapabilityPacks[0]
        try writePackage(manifest, files: [:], at: Path.join(root, "cap"))
        XCTAssertThrowsError(try PackInstaller(registry: registry).installLocalPackage(at: Path.join(root, "cap")))
        XCTAssertThrowsError(try registry.uninstall(manifest.id)) { XCTAssertTrue("\($0)".contains("turn it off")) }
    }

    // MARK: Catalog and external shelves

    /// Stands in for the RoachSpeech model-pack shelf.
    private final class FakeShelf: PackExternalShelf {
        var roots: [String: String] = [:]
        var removed: [String] = []
        func installedRoot(forPack id: String, handler: PackInstallHandler) -> String? { roots[id] }
        func removePack(id: String, handler: PackInstallHandler) throws { roots.removeValue(forKey: id); removed.append(id) }
    }

    private func speechCatalogPack(id: String = "roachvoice-test-coreml") -> PackManifest {
        PackManifest(
            id: id, version: "1.0.0", kind: .resource, name: "Test narrator",
            requires: PackRequirements(roachnet: "1.1.0", platforms: ["macos"]),
            dependencies: [PackDependency(id: "speech", minimumVersion: "1.1.0")],
            capabilities: [.speaker],
            resources: [PackResource(path: "\(id).zip", url: "https://apps.roachnet.org/downloads/model-packs/\(id).json", sha256: String(repeating: "ab", count: 32), bytes: 1234, archive: "zip")],
            install: PackInstallHandler(handler: PackInstallHandler.roachSpeechPack, kind: "roachVoice")
        )
    }

    func testCatalogPacksAreListedAsAvailableUntilTheShelfHasThem() throws {
        let registry = registry()
        let shelf = FakeShelf()
        registry.externalShelf = shelf
        registry.catalogPacks = [speechCatalogPack()]

        let listed = try XCTUnwrap(registry.record("roachvoice-test-coreml"))
        XCTAssertFalse(listed.isInstalled)
        XCTAssertFalse(listed.isEnabled)
        XCTAssertNil(listed.installRoot)
        let json = registry.recordJSON(listed, includeSizes: false)
        XCTAssertEqual(json["available"].truthy, true)
        XCTAssertEqual(json["handler"].jsString, "roachspeech-pack")
        XCTAssertEqual(json["downloadBytes"].jsNumber, 1234)
        XCTAssertThrowsError(try registry.enable("roachvoice-test-coreml"), "nothing to enable before it is installed")

        // The shelf gets the pack (through the speech installer or an older website link).
        shelf.roots["roachvoice-test-coreml"] = Path.join(root, "RoachSpeech/ModelPacks/roachvoice-test-coreml")
        let installed = try XCTUnwrap(registry.record("roachvoice-test-coreml"))
        XCTAssertTrue(installed.isInstalled)
        XCTAssertTrue(installed.isEnabled, "a pack on the shelf is in use")
        XCTAssertEqual(installed.installRoot, shelf.roots["roachvoice-test-coreml"])

        let report = try registry.uninstall("roachvoice-test-coreml")
        XCTAssertEqual(shelf.removed, ["roachvoice-test-coreml"])
        XCTAssertEqual(report.removedPaths, [Path.join(root, "RoachSpeech/ModelPacks/roachvoice-test-coreml")])
        XCTAssertFalse(try XCTUnwrap(registry.record("roachvoice-test-coreml")).isInstalled, "back to available after removal")
    }

    func testInstalledPacksShadowCatalogEntriesAndCatalogNeverHidesBundledPacks() throws {
        let registry = registry()
        registry.catalogPacks = [speechCatalogPack(), PackManifest(id: "roachclaw", version: "9.9.9", kind: .capability, name: "Impostor")]
        let claw = try XCTUnwrap(registry.record("roachclaw"))
        XCTAssertTrue(claw.bundled)
        XCTAssertEqual(claw.manifest.name, "RoachClaw", "the bundled pack wins over a catalog entry with the same id")
        XCTAssertEqual(registry.records().filter { $0.manifest.id == "roachclaw" }.count, 1)
    }

    func testManifestInstallHandlerIsValidated() throws {
        var manifest = speechCatalogPack()
        XCTAssertNoThrow(try manifest.validate())
        let roundTrip = try PackManifest.decode(try manifest.encoded())
        XCTAssertEqual(roundTrip.install?.handler, "roachspeech-pack")
        XCTAssertEqual(roundTrip.install?.kind, "roachVoice")

        manifest.install = PackInstallHandler(handler: "mystery")
        XCTAssertThrowsError(try manifest.validate())
        manifest.install = PackInstallHandler(handler: PackInstallHandler.roachSpeechPack, kind: "roachVoice")
        manifest.resources[0].archive = "tar.gz"
        XCTAssertThrowsError(try manifest.validate(), "the speech installer takes one zip")
        manifest.resources[0].archive = "zip"
        manifest.install = PackInstallHandler(handler: PackInstallHandler.roachSpeechPack, kind: nil)
        XCTAssertThrowsError(try manifest.validate(), "voice or whisper must be named")
    }

    func testPublishedCatalogFileValidates() throws {
        let path = Path.join(Path.dirname(Path.dirname(Path.dirname(Path.dirname(Path.dirname(#filePath))))), "collections", "packs.json")
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("collections/packs.json not beside the package") }
        let file = try JSON.parse(data)
        XCTAssertEqual(file["schema"].jsString, "org.roachnet.packs-catalog.v1")
        let manifests = try file["packs"].array.map { try PackManifest.decode($0.serializedData()) }
        XCTAssertEqual(manifests.count, 3)
        XCTAssertEqual(Set(manifests.map(\.id)).count, manifests.count, "ids are unique")
        for manifest in manifests {
            XCTAssertEqual(manifest.kind, .resource)
            XCTAssertEqual(manifest.install?.handler, "roachspeech-pack")
            XCTAssertTrue(manifest.dependencies.contains { $0.id == "speech" })
            XCTAssertTrue(manifest.resources[0].url?.hasPrefix("https://apps.roachnet.org/downloads/model-packs/") == true)
        }
        let registry = registry()
        registry.catalogPacks = manifests
        XCTAssertEqual(registry.records().filter { !$0.isInstalled }.count, 3, "all three are available on a fresh install")
    }

    func testLiveCatalogOnlyAddsResourcePacksAndNeverOverridesBundledEntries() throws {
        let bundledEntry = speechCatalogPack(id: "roachvoice-bundled")
        let impostor = try JSON.parse(try PackManifest(id: "roachvoice-bundled", version: "9.0.0", kind: .resource, name: "Impostor", resources: bundledEntry.resources, install: bundledEntry.install).encoded())
        let code = try JSON.parse(try PackManifest(id: "sneaky-code", version: "1.0.0", kind: .capability, name: "Sneaky").encoded())
        let fresh = try JSON.parse(try speechCatalogPack(id: "roachvoice-new").encoded())
        let live: JSON = ["schema": JSON(PackCatalogFile.schema), "packs": .array([impostor, code, fresh, fresh])]

        let parsed = PackCatalogFile.parse(live)
        XCTAssertEqual(parsed.manifests.map(\.id), ["roachvoice-bundled", "roachvoice-new"])
        XCTAssertEqual(parsed.skipped.count, 2, "the capability pack and the duplicate are refused: \(parsed.skipped)")

        let merged = PackCatalogFile.merge(bundled: [bundledEntry], live: parsed.manifests)
        XCTAssertEqual(merged.map(\.id), ["roachvoice-bundled", "roachvoice-new"])
        XCTAssertEqual(merged[0].version, "1.0.0", "the bundled entry wins over the live impostor")

        XCTAssertTrue(PackCatalogFile.parse(["schema": "org.roachnet.packs-catalog.v2", "packs": .array([fresh])]).manifests.isEmpty, "unknown schema yields nothing")
    }
}
