import Foundation
import Testing
@testable import UniveEngineKit

@Suite struct WindowsComponentsTests {
    /// A minimal CAB-shaped block: "MSCF", 4 reserved bytes, then the cabinet's size (little-endian).
    func cab(size: Int, fill: UInt8) -> Data {
        var d = Data([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])
        d += withUnsafeBytes(of: UInt32(size).littleEndian) { Data($0) }
        d += Data(repeating: fill, count: size - d.count)
        return d
    }

    @Test func findsTheCabinetsInsideAnInstaller() {
        let stub = Data("MZ stub with a fake MSCF\0\0\0\0 mention".utf8)
        let data = stub + cab(size: 64, fill: 1) + Data(repeating: 0, count: 10) + cab(size: 100, fill: 2)
        let found = WindowsComponents.cabinets(in: data)
        #expect(found.map(\.count) == [64, 100])
        #expect(data[found[1]].last == 2)
    }

    @Test func aMissingDLLPointsToItsComponent() {
        #expect(WindowsComponent.providing(dll: "MSVCP140.dll") == .vcrun2022)
        #expect(WindowsComponent.providing(dll: "d3dx9_43.dll") == .d3dx9)
        #expect(WindowsComponent.providing(dll: "d3dcompiler_43") == .d3dx9)
        #expect(WindowsComponent.providing(dll: "kernel32.dll") == nil)
    }

    @Test func downloadsArePinned() {
        for component in WindowsComponent.allCases {
            for d in component.downloads {
                #expect(d.url.scheme == "https")
                #expect(d.sha256.count == 64 && d.sha256.allSatisfy(\.isHexDigit))
            }
        }
    }

    @Test func installedComponentsAreReadFromTheBottle() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("components-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let bottle = Bottle(kind: .steam, paths: paths)
        let windows = bottle.driveC.appendingPathComponent("windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        #expect(WindowsComponents(paths: paths).installed(in: bottle).isEmpty)
        try #"["vcrun2022","bogus"]"#.write(to: windows.appendingPathComponent(WindowsComponents.record), atomically: true, encoding: .utf8)
        #expect(WindowsComponents(paths: paths).installed(in: bottle) == [.vcrun2022])
    }

    @Test func recipesCantChangeWhatLoads() throws {
        let json = #"""
        {"recipes":{"steam:1":{"components":["vcrun2022"],"dllOverrides":["d3dx9_43=n,b","x=n;rm -rf","bad"],
         "environment":{"DXVK_HUD":"fps","DYLD_INSERT_LIBRARIES":"/tmp/x.dylib","WINEPREFIX":"/tmp","PATH":"/tmp"},
         "arguments":["-dx11","--wrapper","sh -c evil","--wine=/tmp/x","-a;b","/nolauncher","+set"],"backend":"dxvk","note":"Needs the VC++ runtime."}}}
        """#
        let recipe = try #require(GameRecipeBook.decode(Data(json.utf8)).recipe(for: "steam:1"))
        #expect(recipe.components == [.vcrun2022])
        #expect(recipe.dllOverrides == ["d3dx9_43=n,b"])
        #expect(recipe.environment == ["DXVK_HUD": "fps"])
        #expect(recipe.arguments == ["-dx11", "/nolauncher", "+set"])   // no launcher options, no shell text

        var mine = LaunchProfile()
        mine.extraEnvironment = ["DXVK_HUD": "full"]
        mine.extraArguments = ["-windowed"]
        let applied = recipe.applied(to: mine)
        #expect(applied.backend == .dxvk)
        #expect(applied.extraEnvironment["DXVK_HUD"] == "full")      // the player's value wins
        #expect(applied.extraArguments == ["-dx11", "/nolauncher", "+set", "-windowed"])
        #expect(applied.dllOverrides == ["d3dx9_43=n,b"])
        var chosen = LaunchProfile()
        chosen.backend = .wined3d
        #expect(recipe.applied(to: chosen).backend == .wined3d)       // and so does their backend

        let env = WineRunner.environment(bottle: Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/x"))), profile: applied)
        #expect(env["WINEDLLOVERRIDES"]?.hasSuffix("d3dx9_43=n,b") == true)
    }

    @Test func aMissingVCRuntimeOffersToInstallIt() {
        let log = "err:module:import_dll Library MSVCP140.dll (which is needed by L\"C:\\Game\\game.exe\") not found"
        let d = LogDiagnosis(log: log)
        #expect(d.findings.first?.action == .installComponent(.vcrun2022))
    }
}


@Suite struct ShaderCacheAndFrameRateTests {
    @Test func findsDXVKCachesWithoutFollowingLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("caches-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let game = root.appendingPathComponent("steam/drive_c/Games/X")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try Data(count: 10).write(to: game.appendingPathComponent("x.dxvk-cache"))
        try Data(count: 10).write(to: game.appendingPathComponent("save.dat"))
        let outside = fm.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        try Data(count: 10).write(to: outside.appendingPathComponent("y.dxvk-cache"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("steam/drive_c/link"), withDestinationURL: outside)

        let found = ShaderCaches.dxvkCaches(in: root)
        #expect(found.map(\.lastPathComponent) == ["x.dxvk-cache"], "\(found)")
        #expect(ShaderCaches.size(of: found) == 10)
        #expect(ShaderCaches.clear(found) == 10)
        #expect(fm.fileExists(atPath: game.appendingPathComponent("save.dat").path))
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("y.dxvk-cache").path))
    }

    @Test func frameRateLimitOnlyForDXVK() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/x")))
        var p = LaunchProfile()
        p.backend = .dxvk
        p.frameRateLimit = 60
        #expect(WineRunner.environment(bottle: bottle, profile: p)["DXVK_FRAME_RATE"] == "60")
        p.backend = .d3dMetal
        #expect(WineRunner.environment(bottle: bottle, profile: p)["DXVK_FRAME_RATE"] == nil)
        p.backend = .dxvk
        p.frameRateLimit = 0
        #expect(WineRunner.environment(bottle: bottle, profile: p)["DXVK_FRAME_RATE"] == nil)
    }
}
