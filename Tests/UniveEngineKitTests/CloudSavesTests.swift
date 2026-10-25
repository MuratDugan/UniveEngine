import Foundation
import Testing
@testable import UniveEngineKit

@Suite struct CloudSavesTests {
    let bottle = Bottle(kind: .epic, paths: Paths(home: URL(fileURLWithPath: "/tmp/cloud-home")))
    var profile: String { SaveRoots(bottle: bottle, installPath: nil).profile.path }

    @Test func resolvesEpicTemplatesLikeLegendary() throws {
        let install = URL(fileURLWithPath: "/Games/Metro")
        let saved = try #require(CloudSavePath.epic(template: "{UserSavedGames}/metro exodus/{EpicID}/", bottle: bottle,
                                                    installPath: install, accountID: "abc123"))
        #expect(saved.path == profile + "/Saved Games/metro exodus/abc123")
        #expect(CloudSavePath.epic(template: "{AppData}/COB/Saved_EGS/SaveGames/", bottle: bottle, installPath: install, accountID: nil)?.path
                == profile + "/AppData/Local/COB/Saved_EGS/SaveGames")
        #expect(CloudSavePath.epic(template: "{InstallDir}\\\\Saves", bottle: bottle, installPath: install, accountID: nil)?.path == "/Games/Metro/Saves")
        // Unknown or missing variables, and paths that climb out, aren't used.
        #expect(CloudSavePath.epic(template: "{UserSavedGames}/{EpicID}", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{Mystery}/x", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{AppData}/../../../../etc", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{InstallDir}/../Other", bottle: bottle, installPath: install, accountID: nil) == nil)
    }

    @Test func followsParentFoldersInsideTheProfile() throws {
        // Epic's own spelling for LocalLow and Roaming.
        let install = URL(fileURLWithPath: "/Games/Untold")
        #expect(CloudSavePath.epic(template: "{appdata}/../locallow/No Code/", bottle: bottle, installPath: install, accountID: nil)?.path
                == profile + "/AppData/LocalLow/No Code")
        #expect(CloudSavePath.epic(template: "{AppData}/../Roaming/IO Interactive/Epic/{EpicId}/", bottle: bottle, installPath: install,
                                   accountID: "abc")?.path == profile + "/AppData/Roaming/IO Interactive/Epic/abc")
    }

    @Test func neverThroughLinksOrTheRootItself() throws {
        // A profile like Wine's: Downloads is a link to the Mac's own folder.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-links-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .epic, paths: Paths(home: home))
        let profile = SaveRoots(bottle: bottle, installPath: nil).profile
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("AppData/Local"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Downloads"), withDestinationURL: home)
        let install = home.appendingPathComponent("Game")
        #expect(CloudSavePath.epic(template: "{UserProfile}/Downloads/x", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{UserProfile}/downloads", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{UserProfile}", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{InstallDir}/", bottle: bottle, installPath: install, accountID: nil) == nil)
        #expect(CloudSavePath.epic(template: "{AppData}/Game", bottle: bottle, installPath: install, accountID: nil)?.path
                == profile.path + "/AppData/Local/Game")
        // A real folder (here under /private/var) with "..": the same place, however macOS spells it.
        let low = try #require(CloudSavePath.epic(template: "{AppData}/../LocalLow/No Code", bottle: bottle, installPath: install, accountID: nil))
        #expect(CloudSavePath.canonical(low).path == CloudSavePath.canonical(profile).path + "/AppData/LocalLow/No Code")
    }

    @Test func substitutesOnce() {
        #expect(CloudSavePath.substitute("{a}/x/{A}", ["{a}": "/v/{a}"]) == "/v/{a}/x//v/{a}")
    }

    @Test func usesTheCaseOfExistingFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-case-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppData/LocalLow"), withIntermediateDirectories: true)
        let url = CloudSavePath.matchingCase(root.appendingPathComponent("appdata/locallow/No Code"), under: root)
        #expect(url.path == root.path + "/AppData/LocalLow/No Code")
    }

    @Test func resolvesGOGLocations() throws {
        let install = URL(fileURLWithPath: "/Games/Witcher")
        #expect(CloudSavePath.gog(location: "<?APPLICATION_DATA_ROAMING?>/CDProjektRed/saves", bottle: bottle, installPath: install)?.path
                == profile + "/AppData/Roaming/CDProjektRed/saves")
        #expect(CloudSavePath.gog(location: "<?INSTALL?>/save", bottle: bottle, installPath: install)?.path == "/Games/Witcher/save")
        #expect(CloudSavePath.gog(location: "<?UNKNOWN?>/x", bottle: bottle, installPath: install) == nil)
    }

    @Test func readsGOGRemoteConfig() {
        let config = Data(#"{"content":{"Windows":{"cloudStorage":{"enabled":true,"locations":[{"name":"saves","location":"<?DOCUMENTS?>/Game"}]}}}}"#.utf8)
        #expect(GOGProvider.cloudLocations(remoteConfig: config, clientID: "1") == [.init(name: "saves", location: "<?DOCUMENTS?>/Game")])
        let defaults = Data(#"{"content":{"Windows":{"cloudStorage":{"enabled":true}}}}"#.utf8)
        #expect(GOGProvider.cloudLocations(remoteConfig: defaults, clientID: "42").first?.location.contains("Applications/42/Storage") == true)
        let off = Data(#"{"content":{"Windows":{"cloudStorage":{"enabled":false}}}}"#.utf8)
        #expect(GOGProvider.cloudLocations(remoteConfig: off, clientID: "1").isEmpty)
    }
}
