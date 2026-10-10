import XCTest
@testable import RoachNetApp

/// The sidebar mounts panes from the runtime's pack registry. Before the first
/// read it must use what it remembered, and it must never hide a pane the
/// runtime does not know about.
@MainActor
final class FeaturePackTests: XCTestCase {
    private func catalog(enabled: [String: Bool], sizes: Bool = false) -> Data {
        let packs = enabled.map { id, on -> String in
            """
            {"id":"\(id)","version":"1.1.0","kind":"capability","name":"\(id.capitalized)","summary":"","publisher":"RoachWares LLC",
             "bundled":true,"installed":true,"enabled":\(on),"installedVersion":"1.1.0","installedBytes":\(sizes ? "1024" : "null"),
             "dependencies":\(id == "org" ? #"[{"id":"roachclaw","minimumVersion":"1.1.0"}]"# : "[]"),
             "dependents":\(id == "roachclaw" ? #"["org"]"# : "[]"),"capabilities":["inference"],
             "dataRoots":[{"path":"\(id)","description":"Data","exists":true,"bytes":\(sizes ? "2048" : "null")}],
             "compatibility":{"ok":true},"unresolvedDependencies":[]}
            """
        }
        return Data("""
        {"success":true,"schema":"org.roachnet.packs.v1","appVersion":"1.1.0","platform":"macos","packsRoot":"/tmp/packs",
         "sizesIncluded":\(sizes),"packs":[\(packs.joined(separator: ","))],"jobs":[]}
        """.utf8)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "roachnet.tests.packs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEverythingMountsBeforeTheFirstReadAndCorePanesAlways() {
        let store = FeaturePackStore(defaults: freshDefaults())
        for pane in WorkspacePane.allCases {
            XCTAssertTrue(store.isMounted(pane), "\(pane) must mount before the registry answers")
        }
    }

    func testDisabledPackUnmountsItsPaneAndIsRememberedForNextLaunch() throws {
        let defaults = freshDefaults()
        let store = FeaturePackStore(defaults: defaults)
        try store.load(catalogJSON: catalog(enabled: ["roachclaw": true, "org": false, "arcade": true, "vault": true]))
        XCTAssertFalse(store.isMounted(.org))
        XCTAssertTrue(store.isMounted(.roachClaw))
        XCTAssertTrue(store.isMounted(.knowledge))
        XCTAssertTrue(store.isMounted(.home))
        XCTAssertTrue(store.isMounted(.runtime))
        XCTAssertTrue(store.isMounted(.maps), "a pane whose pack the runtime did not list is never hidden")

        // A new store on the same defaults (next launch) hides Org before any request.
        let relaunched = FeaturePackStore(defaults: defaults)
        XCTAssertFalse(relaunched.isMounted(.org))
        XCTAssertTrue(relaunched.isMounted(.roachClaw))
    }

    func testDependentsBlockDisablingAndSizesSurviveCheapRefreshes() throws {
        let store = FeaturePackStore(defaults: freshDefaults())
        try store.load(catalogJSON: catalog(enabled: ["roachclaw": true, "org": true], sizes: true), includedSizes: true)
        XCTAssertEqual(store.dependentsBlockingDisable(of: store.pack("roachclaw")!), ["org"])
        XCTAssertEqual(store.dependentsBlockingDisable(of: store.pack("org")!), [])
        XCTAssertEqual(store.pack("org")?.installedBytes, 1024)
        XCTAssertEqual(store.pack("org")?.dataBytes, 2048)

        try store.load(catalogJSON: catalog(enabled: ["roachclaw": true, "org": false]))
        XCTAssertFalse(store.pack("org")!.enabled)
        XCTAssertEqual(store.pack("org")?.installedBytes, 1024, "a refresh without sizes keeps the sizes the manager fetched")
        XCTAssertEqual(store.pack("org")?.dataBytes, 2048)
        XCTAssertEqual(store.dependentsBlockingDisable(of: store.pack("roachclaw")!), [], "a disabled dependent no longer blocks")
    }

    func testUnknownSchemaIsRejected() {
        let store = FeaturePackStore(defaults: freshDefaults())
        XCTAssertThrowsError(try store.load(catalogJSON: Data(#"{"schema":"org.roachnet.packs.v9","packs":[],"jobs":[]}"#.utf8)))
        XCTAssertFalse(store.loaded)
    }

    func testCapabilityLabelsAreWordsPeopleRecognise() {
        XCTAssertEqual(FeaturePacksSettingsView.capabilityLabel("network.public"), "Internet")
        XCTAssertEqual(FeaturePacksSettingsView.capabilityLabel("process.spawn"), "Runs programs")
        XCTAssertEqual(FeaturePacksSettingsView.capabilityLabel("something.new"), "something.new")
    }

    func testAvailableCatalogPacksAreListedSeparatelyUntilInstalled() throws {
        let store = FeaturePackStore(defaults: freshDefaults())
        func catalog(installed: Bool) -> Data {
            Data("""
            {"success":true,"schema":"org.roachnet.packs.v1","packs":[
              {"id":"speech","version":"1.1.0","kind":"capability","name":"RoachSpeech","bundled":true,"installed":true,"enabled":true,
               "dependencies":[],"dependents":[],"capabilities":[],"dataRoots":[]},
              {"id":"roachvoice-kokoro-82m-int8-coreml","version":"1.0.0","kind":"resource","name":"RoachVoice Small Narrator",
               "bundled":false,"installed":\(installed),"available":\(!installed),"handler":"roachspeech-pack","enabled":\(installed),
               "downloadBytes":80330676,"dependencies":[{"id":"speech","minimumVersion":"1.1.0"}],"dependents":[],"capabilities":["speaker"],"dataRoots":[]}
            ],"jobs":[]}
            """.utf8)
        }
        try store.load(catalogJSON: catalog(installed: false))
        XCTAssertEqual(store.availablePacks.map(\.id), ["roachvoice-kokoro-82m-int8-coreml"])
        XCTAssertTrue(store.resourcePacks.isEmpty)
        XCTAssertEqual(store.capabilityPacks.map(\.id), ["speech"])
        XCTAssertTrue(store.isMounted(.roachClaw), "resource packs never gate a pane")

        try store.load(catalogJSON: catalog(installed: true))
        XCTAssertTrue(store.availablePacks.isEmpty)
        XCTAssertEqual(store.resourcePacks.map(\.id), ["roachvoice-kokoro-82m-int8-coreml"])
    }
}
