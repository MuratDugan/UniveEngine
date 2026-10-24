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
        missing(present: valueNames(userReg: text))
    }

    static func missing(present names: [String]) -> [(name: String, value: UInt32)] {
        let present = Set(names.map { $0.lowercased() })
        return values.filter { !present.contains($0.name.lowercased()) }
    }

    /// Value names in `reg query` output (`    Name    REG_DWORD    0x1002`), of any type.
    static func valueNames(regQuery output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.components(separatedBy: "    ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return fields.count >= 2 && fields[1].hasPrefix("REG_") ? fields[0] : nil
        }
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
    /// Adds the missing `GPUIdentity` values. Direct3D reads them when each program starts, so they can be added
    /// while the bottle runs (Steam usually stays open): the running wineserver is then asked and written to, since
    /// its `user.reg` may be minutes old. Nothing is written when the registry can't be read.
    func syncGPUIdentity(engine: Engine, bottle: Bottle) async {
        guard let data = try? Data(contentsOf: bottle.url.appendingPathComponent("user.reg"), options: .mappedIfSafe) else { return }
        var missing = GPUIdentity.missing(userReg: String(decoding: data, as: UTF8.self))
        guard !missing.isEmpty else { return }
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        func reg(_ args: [String]) async -> ProcessResult? { try? await ProcessRunner.run(engine.wine, ["reg"] + args, environment: env) }

        if await isBottleActive(engine: engine, bottle: bottle) {
            if let r = await reg(["query", GPUIdentity.key]), r.succeeded {
                missing = GPUIdentity.missing(present: GPUIdentity.valueNames(regQuery: r.output))
            } else if let parent = await reg(["query", #"HKCU\Software\Wine"#]), parent.succeeded {
                missing = GPUIdentity.values   // the server answers, the key just doesn't exist yet
            } else {
                return   // another engine's server, or none reachable: leave it for the next launch
            }
        }
        for (name, value) in missing {
            _ = await reg(["add", GPUIdentity.key, "/v", name, "/t", "REG_DWORD", "/d", String(format: "0x%x", value), "/f"])
        }
    }
}
