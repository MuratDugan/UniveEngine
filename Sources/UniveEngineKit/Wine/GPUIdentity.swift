import Foundation

/// The graphics card Direct3D reports through Wine's own DXGI, which DXVK and WineD3D both use.
///
/// Wine's card table has no Apple GPUs, so without this every game sees an "NVIDIA GeForce 6800" from 2004 and
/// picks its lowest settings, or refuses to start. A Radeon RX 5700 is a DirectX 12 card about as fast as an
/// M-series GPU, and AMD has no driver extensions that games require. Engines whose DXGI isn't Wine's (D3DMetal,
/// DXMT) report Apple's GPU themselves and ignore these values. A value the bottle already has is never changed,
/// so a card someone chose with `regedit` stays.
public enum GPUIdentity {
    public static let key = #"HKCU\Software\Wine\Direct3D"#
    static let userRegSection = #"[Software\\Wine\\Direct3D]"#
    public static let values: [(name: String, value: UInt32)] = [("VideoPciVendorID", 0x1002), ("VideoPciDeviceID", 0x731f)]

    /// The values `user.reg` doesn't set yet, of any type.
    public static func missing(userReg text: String) -> [(name: String, value: UInt32)] {
        let present = Set(valueNames(userReg: text).map { $0.lowercased() })
        return values.filter { !present.contains($0.name.lowercased()) }
    }

    static func valueNames(userReg text: String) -> [String] {
        guard let header = MacDriver.sectionStart(in: text, section: userRegSection) else { return [] }
        var names: [String] = []
        for line in text[header...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).dropFirst() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") { break }
            if let (name, rest) = MacDriver.quoted(line[...]), rest.hasPrefix("=") { names.append(name) }
        }
        return names
    }
}

public extension WineRunner {
    /// Adds the missing `GPUIdentity` values. Only while the bottle is idle: `user.reg` is then what the next
    /// wineserver loads, and Direct3D reads the values when a program starts.
    func syncGPUIdentity(engine: Engine, bottle: Bottle) async {
        guard let data = try? Data(contentsOf: bottle.url.appendingPathComponent("user.reg"), options: .mappedIfSafe) else { return }
        let missing = GPUIdentity.missing(userReg: String(decoding: data, as: UTF8.self))
        guard !missing.isEmpty, !(await isBottleActive(engine: engine, bottle: bottle)) else { return }
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        for (name, value) in missing {
            _ = try? await ProcessRunner.run(engine.wine, ["reg", "add", GPUIdentity.key, "/v", name, "/t", "REG_DWORD",
                                                           "/d", String(format: "0x%x", value), "/f"], environment: env)
        }
    }
}
