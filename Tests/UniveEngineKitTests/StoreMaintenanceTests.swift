import Foundation
import Testing
@testable import UniveEngineKit

@Suite struct StoreMaintenanceTests {
    @Test func epicUpdatesCompareTheInstalledBuildWithTheStore() {
        let list = Data(#"""
        [{"app_name":"Sugar","app_title":"Hades","asset_infos":{"Windows":{"build_version":"1.2"}}},
         {"app_name":"Fresh","app_title":"Same","asset_infos":{"Windows":{"build_version":"7"}}},
         {"app_name":"NotInstalled","app_title":"X","asset_infos":{"Windows":{"build_version":"3"}}}]
        """#.utf8)
        let installed = Data(#"""
        [{"app_name":"Sugar","install_path":"/g/Hades","version":"1.1"},
         {"app_name":"Fresh","install_path":"/g/Same","version":"7"}]
        """#.utf8)
        #expect(LegendaryParser.updates(listJSON: list, installedJSON: installed) == ["Sugar"])
        #expect(LegendaryParser.updates(listJSON: Data("nope".utf8), installedJSON: installed).isEmpty)
    }

    @Test func movingAGOGGameKeepsItPlayableAndUninstallable() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("gogmove-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let gog = GOGProvider(paths: Paths(home: home), gamesFolder: home.appendingPathComponent("Games"))   // never ~/Games
        let game = Game(store: .gog, storeID: "123", title: "Test", isInstalled: true)
        let folder = gog.gamesFolder.appendingPathComponent("Test Game")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("goggame-123.info"))
        var installed = GOGInstalled()
        installed.games["123"] = .init(title: "Test", path: folder)
        try gog.saveInstalled(installed)

        let elsewhere = home.appendingPathComponent("External Disk/Games")
        try gog.move(game, to: elsewhere)
        let moved = elsewhere.appendingPathComponent("Test Game")
        #expect(fm.fileExists(atPath: moved.appendingPathComponent("goggame-123.info").path))
        #expect(gog.loadInstalled().games["123"]?.path == moved)
        #expect(!fm.fileExists(atPath: folder.path))

        try gog.uninstall(game)
        #expect(!fm.fileExists(atPath: moved.path))
        #expect(gog.loadInstalled().games["123"] == nil)
    }
}
