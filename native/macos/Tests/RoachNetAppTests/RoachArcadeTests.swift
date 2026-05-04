import XCTest
@testable import RoachNetApp

final class RoachArcadeTests: XCTestCase {
    func testCoreResolverMapsCommonRomExtensions() {
        XCTAssertEqual(
            RoachArcadeCoreResolver.core(forSystem: "Super Nintendo", path: "/Games/Chrono Trigger.sfc"),
            "snes"
        )
        XCTAssertEqual(
            RoachArcadeCoreResolver.core(forSystem: "Nintendo 64", path: "/Games/Mario.z64"),
            "n64"
        )
        XCTAssertEqual(
            RoachArcadeCoreResolver.core(forSystem: "Game Boy Advance", path: "/Games/Metroid.gba"),
            "gba"
        )
    }

    func testRomGameStoresCheatsAndUsesResolvedCore() {
        var game = RoachArcadeGame(
            title: "Demo ROM",
            kind: .rom,
            system: "NES",
            source: "Local ROM folder",
            romPath: "/tmp/demo.nes",
            tags: ["retro"]
        )
        game.cheats.append(RoachArcadeCheat(name: "Infinite Lives", code: "SXIOPO"))

        XCTAssertEqual(game.resolvedCore, "nes")
        XCTAssertEqual(game.cheats.first?.name, "Infinite Lives")
        XCTAssertEqual(game.tags, ["retro"])
    }

    func testWorkspacePaneExposesRoachArcadeAsNativeSurface() {
        XCTAssertTrue(WorkspacePane.allCases.contains(.arcade))
        XCTAssertEqual(WorkspacePane.arcade.icon, "gamecontroller.fill")
        XCTAssertEqual(WorkspacePane.arcade.subtitle, "Native games")
    }

    func testGameDecodesLegacyLibraryWithoutCompatibilityRunner() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Old ROM",
          "kind": "rom",
          "system": "NES",
          "source": "Legacy library",
          "status": "tracked",
          "romPath": "/tmp/old.nes",
          "notes": "",
          "tags": [],
          "cheats": [],
          "playCount": 0,
          "createdAt": "2026-05-02T00:00:00Z",
          "updatedAt": "2026-05-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let game = try decoder.decode(RoachArcadeGame.self, from: Data(json.utf8))

        XCTAssertEqual(game.compatibilityRunner, .native)
        XCTAssertEqual(game.resolvedCore, "nes")
    }

    @MainActor
    func testLibraryStoreTogglesCheatsAndStoresModDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoachArcadeTests-\(UUID().uuidString)", isDirectory: true)
        let romURL = root.appendingPathComponent("demo.nes")
        let modURL = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x4e, 0x45, 0x53]).write(to: romURL)
        try FileManager.default.createDirectory(at: modURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = RoachArcadeLibraryStore()
        store.configure(storagePath: root.path)
        store.importROMFolder(root)

        let game = try XCTUnwrap(store.games.first)
        store.addCheat(to: game.id, name: "Infinite Lives", code: "SXIOPO")
        let cheat = try XCTUnwrap(store.games.first?.cheats.first)
        XCTAssertTrue(cheat.enabled)

        store.toggleCheat(cheat.id, for: game.id)
        XCTAssertFalse(try XCTUnwrap(store.games.first?.cheats.first).enabled)

        store.setModDirectory(modURL, for: game.id)
        XCTAssertEqual(store.games.first?.modDirectoryPath, modURL.path)
    }

    @MainActor
    func testWindowsGameNeedsRunnerBeforeItClaimsReady() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoachArcadeRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let executableURL = root.appendingPathComponent("DemoGame.exe")
        let runnerURL = root.appendingPathComponent("runner.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: executableURL)
        try Data("#!/bin/sh\n".utf8).write(to: runnerURL)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = RoachArcadeLibraryStore()
        store.configure(storagePath: root.path)

        var game = RoachArcadeGame(
            title: "Demo Windows Game",
            kind: .windows,
            system: "Windows",
            source: "Test fixture",
            executablePath: executableURL.path,
            compatibilityRunner: .external
        )
        store.addGame(game)
        XCTAssertEqual(store.games.first?.status, .needsRunner)

        game.runnerPath = runnerURL.path
        store.addGame(game)
        XCTAssertEqual(store.games.first?.status, .ready)
    }
}
