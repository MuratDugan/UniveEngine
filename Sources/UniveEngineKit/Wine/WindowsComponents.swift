import Foundation

/// Microsoft runtimes many games need and Wine doesn't fully replace, installed into a bottle the way winetricks
/// does it: Microsoft's own redistributables, downloaded from Microsoft, checked against pinned SHA-256s (the same
/// ones winetricks pins), unpacked with macOS's own `bsdtar` (it reads the CAB archives inside them), and the DLLs
/// copied into the bottle with their load order set to prefer them.
public enum WindowsComponent: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Visual C++ 2015–2022 runtime (msvcp140, vcruntime140…), 32- and 64-bit.
    case vcrun2022
    /// DirectX 9 helper libraries (d3dx9_24 … d3dx9_43) and d3dcompiler_43 from the June 2010 DirectX runtime.
    case d3dx9

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vcrun2022: "Visual C++ 2015–2022"
        case .d3dx9: "DirectX 9 (d3dx9)"
        }
    }

    struct Download: Sendable {
        let url: URL
        let sha256: String
        var name: String { url.lastPathComponent }
    }

    var downloads: [Download] {
        switch self {
        case .vcrun2022: [
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!,
                     sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64"),
            Download(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!,
                     sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"),
        ]
        case .d3dx9: [
            Download(url: URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!,
                     sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"),
        ]
        }
    }

    /// Approximate download, for the button.
    public var downloadMegabytes: Int { self == .vcrun2022 ? 40 : 96 }

    /// DLLs whose load order becomes native,builtin in the bottle: the Microsoft copy first.
    public var overrides: [String] {
        switch self {
        case .vcrun2022:
            ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
             "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"]
        case .d3dx9:
            (24...43).map { "d3dx9_\($0)" } + ["d3dcompiler_43"]
        }
    }

    /// The component a missing DLL belongs to (for "why didn't it start").
    public static func providing(dll: String) -> WindowsComponent? {
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        return allCases.first { $0.overrides.contains(name) }
    }
}

public enum WindowsComponentError: LocalizedError, Equatable {
    case download(String), damaged(String), unpack(String)
    public var errorDescription: String? {
        switch self {
        case .download(let what): "Couldn't download \(what) from Microsoft."
        case .damaged(let what): "\(what) from Microsoft failed its integrity check."
        case .unpack(let what): "Couldn't unpack \(what)."
        }
    }
}

public struct WindowsComponents: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// Records which components a bottle has (next to Windows' own folders).
    static let record = ".univegame-components.json"

    public func installed(in bottle: Bottle) -> Set<WindowsComponent> {
        let file = bottle.driveC.appendingPathComponent("windows/\(Self.record)")
        guard let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids.compactMap(WindowsComponent.init(rawValue:)))
    }

    private func markInstalled(_ component: WindowsComponent, in bottle: Bottle) throws {
        let all = (installed(in: bottle).union([component])).map(\.rawValue).sorted()
        try JSONEncoder().encode(all).write(to: bottle.driveC.appendingPathComponent("windows/\(Self.record)"), options: .atomic)
    }

    var cache: URL { paths.tools.appendingPathComponent("Microsoft", isDirectory: true) }

    /// Installs `component` into `bottle` (again, when asked: it repairs a damaged copy).
    public func install(_ component: WindowsComponent, in bottle: Bottle, engine: Engine,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let files = try await fetch(component.downloads, progress: progress)
        let work = fm.temporaryDirectory.appendingPathComponent("univegame-\(component.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let system64 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        let system32 = bottle.driveC.appendingPathComponent("windows/syswow64", isDirectory: true)
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())

        switch component {
        case .vcrun2022:
            for (file, x64) in zip(files, [false, true]) {
                // The installer registers the runtime (some games check the registry) but skips msvcp140 under Wine,
                // whose own copy has a higher version number (Wine bug 57518), so the DLLs are copied in as well.
                _ = try? await ProcessRunner.run(engine.wine, [Self.windowsPath(file), "/install", "/quiet", "/norestart"], environment: env)
                let suffix = x64 ? "_amd64" : "_x86"
                let dlls = try await Self.extract(from: file, cabMember: x64 ? "a12" : "a10", matching: { $0.hasSuffix(suffix) },
                                                  into: work.appendingPathComponent(suffix, isDirectory: true))
                try Self.copy(dlls, to: x64 ? system64 : system32) { String($0.dropLast(suffix.count)) }
            }
        case .d3dx9:
            guard let redist = files.first else { throw WindowsComponentError.download(component.title) }
            for x64 in [false, true] {
                let arch = x64 ? "_x64.cab" : "_x86.cab"
                let wanted: (String) -> Bool = { name in
                    let n = name.lowercased()
                    return n.hasSuffix(arch.lowercased()) && (n.contains("_d3dx9_") || n.contains("d3dcompiler_43"))
                }
                let inner = try await Self.extract(from: redist, cabMember: nil, matching: wanted,
                                                   into: work.appendingPathComponent("cabs\(arch)", isDirectory: true))
                var dlls: [URL] = []
                for cab in inner {
                    dlls += try await Self.unpack(cab, matching: { $0.lowercased().hasSuffix(".dll") },
                                                  into: work.appendingPathComponent("dll\(arch)/\(cab.lastPathComponent)", isDirectory: true))
                }
                try Self.copy(dlls, to: x64 ? system64 : system32) { $0 }
            }
        }
        for dll in component.overrides {
            _ = try? await ProcessRunner.run(engine.wine, ["reg", "add", #"HKCU\Software\Wine\DllOverrides"#, "/v", dll,
                                                           "/d", "native,builtin", "/f"], environment: env)
        }
        try markInstalled(component, in: bottle)
    }

    // MARK: Downloads

    /// Each file from the cache, or downloaded and checked first. Progress covers all files.
    func fetch(_ downloads: [WindowsComponent.Download], progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        var result: [URL] = []
        for (index, item) in downloads.enumerated() {
            let file = cache.appendingPathComponent(item.name)
            if fm.fileExists(atPath: file.path), (try? EngineManager.sha256(of: file)) == item.sha256 {
                result.append(file)
                continue
            }
            let part = cache.appendingPathComponent(item.name + ".part")
            let base = Double(index) / Double(downloads.count), share = 1 / Double(downloads.count)
            do {
                try await EngineManager.download(item.url, to: part,
                                                 policy: DownloadPolicy(hosts: ["download.visualstudio.microsoft.com", "download.microsoft.com"],
                                                                        maximumSize: 200 << 20)) { progress(base + share * $0) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw WindowsComponentError.download(item.name)
            }
            guard try EngineManager.sha256(of: part) == item.sha256 else {
                try? fm.removeItem(at: part)
                throw WindowsComponentError.damaged(item.name)
            }
            try? fm.removeItem(at: file)
            try fm.moveItem(at: part, to: file)
            result.append(file)
        }
        progress(1)
        return result
    }

    // MARK: Unpacking

    static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }

    /// The CAB archives inside a Microsoft installer (`MSCF` blocks, each sized by its own header).
    static func cabinets(in data: Data) -> [Range<Int>] {
        let magic = Data([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])
        var found: [Range<Int>] = []
        var i = data.startIndex
        while i + 12 <= data.endIndex, let r = data.range(of: magic, in: i..<data.endIndex) {
            let at = r.lowerBound
            guard at + 12 <= data.endIndex else { break }
            let size = Int(data[at + 8]) | Int(data[at + 9]) << 8 | Int(data[at + 10]) << 16 | Int(data[at + 11]) << 24
            if size > 36, at + size <= data.endIndex {
                found.append(at..<(at + size))
                i = at + size
            } else {
                i = at + 4
            }
        }
        return found
    }

    /// Members of the CABs inside `installer` whose names match, unpacked into `folder`. With `cabMember`, that
    /// member is a CAB itself and the match applies inside it.
    static func extract(from installer: URL, cabMember: String?, matching: @escaping (String) -> Bool, into folder: URL) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Data(contentsOf: installer, options: .mappedIfSafe)
        var out: [URL] = []
        for (n, range) in cabinets(in: data).enumerated() {
            let cab = folder.appendingPathComponent("outer\(n).cab")
            try data[range].write(to: cab)
            if let member = cabMember {
                let inner = try await unpack(cab, matching: { $0 == member }, into: folder.appendingPathComponent("outer\(n)", isDirectory: true))
                for innerCab in inner {
                    out += try await unpack(innerCab, matching: matching, into: folder.appendingPathComponent("inner\(n)", isDirectory: true))
                }
            } else {
                out += try await unpack(cab, matching: matching, into: folder.appendingPathComponent("outer\(n)", isDirectory: true))
            }
        }
        guard !out.isEmpty else { throw WindowsComponentError.unpack(installer.lastPathComponent) }
        return out
    }

    /// The members of one CAB whose names match, unpacked by `bsdtar`. Names with a path are refused.
    static func unpack(_ cab: URL, matching: (String) -> Bool, into folder: URL) async throws -> [URL] {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let list = try await ProcessRunner.run(tar, ["-tf", cab.path])
        guard list.succeeded else { return [] }
        let names = list.output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") && matching($0) }
        guard !names.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r = try await ProcessRunner.run(tar, ["-xf", cab.path, "-C", folder.path] + names)
        guard r.succeeded else { throw WindowsComponentError.unpack(cab.lastPathComponent) }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// Copies DLLs into a Windows system folder, named by `rename` (e.g. "msvcp140.dll_amd64" → "msvcp140.dll").
    static func copy(_ files: [URL], to folder: URL, rename: (String) -> String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let name = rename(file.lastPathComponent).lowercased()
            guard name.hasSuffix(".dll") else { continue }
            let target = folder.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: file, to: target)
        }
    }
}
