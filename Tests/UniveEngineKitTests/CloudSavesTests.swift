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
