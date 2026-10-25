import Foundation

/// Where a store's cloud saves live in a bottle. Epic and GOG describe save folders with Windows variables
/// (`{AppData}/Game/Saves`, `<?APPLICATION_DATA_LOCAL?>/Game`); these resolve them the way Legendary and Heroic do,
/// against the bottle's Windows user folders.
public enum CloudSavePath {
    public enum Direction: Sendable {
        /// Newer side wins (the usual sync).
        case both
        /// Only take the cloud's saves (before playing).
        case download
        /// Only send this Mac's saves (after playing).
        case upload
    }

    /// The bottle user's Windows profile folder (`C:\users\<name>`), as save backups use it. Which name that is
    /// depends on the engine that created the bottle (the Mac user's, or `crossover`), so the bottle must exist.
    static func profile(of bottle: Bottle) -> URL { SaveRoots(bottle: bottle, installPath: nil).profile }

    /// Documents, which Wine links to the Mac's Documents folder.
    static func documents(of bottle: Bottle) -> URL {
        profile(of: bottle).appendingPathComponent("Documents").resolvingSymlinksInPath()
    }

    /// Epic's `CloudSaveFolder`: {InstallDir}, {EpicID}, {AppData} (which is *Local* AppData), {UserDir} (Documents),
    /// {UserProfile}, {UserSavedGames}. Nil when something is left unresolved.
    public static func epic(template: String, bottle: Bottle, installPath: URL, accountID: String?) -> URL? {
        let profile = profile(of: bottle)
        var vars: [String: String] = [
            "{installdir}": installPath.path,
            "{appdata}": profile.appendingPathComponent("AppData/Local").path,
            "{userdir}": documents(of: bottle).path,
            "{userprofile}": profile.path,
            "{usersavedgames}": profile.appendingPathComponent("Saved Games").path,
        ]
        if let accountID, accountID.allSatisfy({ $0.isLetter || $0.isNumber }) { vars["{epicid}"] = accountID }
        return resolve(template.replacingOccurrences(of: "\\", with: "/"), vars, open: "{", close: "}", within: [profile, documents(of: bottle), installPath])
    }

    /// GOG Galaxy's cloud storage `location`: <?INSTALL?>, <?DOCUMENTS?>, <?SAVED_GAMES?>,
    /// <?APPLICATION_DATA_LOCAL?>, <?APPLICATION_DATA_LOCAL_LOW?>, <?APPLICATION_DATA_ROAMING?>.
    public static func gog(location: String, bottle: Bottle, installPath: URL) -> URL? {
        let profile = profile(of: bottle)
        let vars: [String: String] = [
            "<?install?>": installPath.path,
            "<?documents?>": documents(of: bottle).path,
            "<?saved_games?>": profile.appendingPathComponent("Saved Games").path,
            "<?application_data_local?>": profile.appendingPathComponent("AppData/Local").path,
            "<?application_data_local_low?>": profile.appendingPathComponent("AppData/LocalLow").path,
            "<?application_data_roaming?>": profile.appendingPathComponent("AppData/Roaming").path,
        ]
        return resolve(location.replacingOccurrences(of: "\\", with: "/"), vars, open: "<?", close: "?>", within: [profile, documents(of: bottle), installPath])
    }

    /// Replaces each variable (case-insensitively, in one pass). The result must be absolute, below one of `roots`
    /// once ".." is applied (Epic writes Roaming and LocalLow as `{AppData}/../Roaming`), and not pass through a
    /// link: Wine links Desktop, Downloads and the like to the Mac's own folders, which a cloud sync must not touch.
    static func resolve(_ template: String, _ vars: [String: String], open: String, close: String, within roots: [URL]) -> URL? {
        let out = substitute(template, vars)
        guard out.hasPrefix("/"), !out.contains(open), !out.contains(close) else { return nil }
        let url = canonical(URL(fileURLWithPath: out, isDirectory: true))
        guard let root = roots.map(canonical).first(where: { url.path.hasPrefix($0.path + "/") }) else { return nil }
        let resolved = matchingCase(url, under: root)
        var walk = root
        for part in resolved.path.dropFirst(root.path.count).split(separator: "/") {
            walk.appendPathComponent(String(part), isDirectory: true)
            if FileScan.isSymlink(walk) { return nil }
        }
        return resolved
    }

    /// Standardized, and without `/private` before tmp, var and etc: macOS drops it from paths that exist but keeps
    /// it in ones with ".." (or not there yet), and the two must compare equal.
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where path.hasPrefix(prefix) {
            return URL(fileURLWithPath: String(path.dropFirst("/private".count)), isDirectory: true)
        }
        return url.standardizedFileURL
    }

    /// Left to right, so a value that contains a variable's name is never replaced again.
    static func substitute(_ template: String, _ vars: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while !rest.isEmpty {
            let next = vars.compactMap { name, value in rest.range(of: name, options: .caseInsensitive).map { ($0, value) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, value) = next else { out += rest; break }
            out += rest[..<range.lowerBound] + value
            rest = rest[range.upperBound...]
        }
        return out
    }

    /// `AppData/locallow` as the folder that's there (`LocalLow`), or Windows' own spelling when it isn't there yet,
    /// so a case-sensitive volume doesn't get a second one.
    static func matchingCase(_ url: URL, under root: URL) -> URL {
        var result = root
        for part in url.path.dropFirst(root.path.count).split(separator: "/").map(String.init) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: result.path)) ?? []
            let name = names.contains(part) ? part
                : names.first { $0.caseInsensitiveCompare(part) == .orderedSame }
                ?? windowsNames.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part
            result.appendPathComponent(name, isDirectory: true)
        }
        return result
    }

    static let windowsNames = ["AppData", "Local", "LocalLow", "Roaming", "Documents", "Saved Games", "My Games"]
}

public extension EpicProvider {
    /// The game's `CloudSaveFolder`, from Legendary's metadata. Nil when the game has no cloud saves.
    func cloudSaveTemplate(_ game: Game) -> String? {
        let file = paths.legendaryConfig.appendingPathComponent("metadata/\(game.storeID).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["metadata"] as? [String: Any],
              let attrs = meta["customAttributes"] as? [String: Any],
              let folder = attrs["CloudSaveFolder"] as? [String: Any],
              let value = folder["value"] as? String, !value.isEmpty else { return nil }
        return value
    }

    var accountID: String? {
        guard let data = try? Data(contentsOf: paths.legendaryConfig.appendingPathComponent("user.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["account_id"] as? String
    }

    /// Syncs the game's saves with Epic's cloud. The save folder is resolved here and handed to Legendary, so it
    /// never asks; `-y` answers its other questions (newer side wins).
    func syncSaves(_ game: Game, bottle: Bottle, direction: CloudSavePath.Direction = .both) async throws {
        guard bottle.exists else { throw EpicError.commandFailed("Start \(game.title) once first, so its saves have a place to go.") }
        guard let install = game.installPath, let template = cloudSaveTemplate(game),
              let folder = CloudSavePath.epic(template: template, bottle: bottle, installPath: install, accountID: accountID) else {
            throw EpicError.commandFailed("\(game.title) has no cloud saves.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var args = ["-y", "sync-saves", game.storeID, "--save-path", folder.path]
        switch direction {
        case .both: break
        case .download: args.append("--skip-upload")
        case .upload: args.append("--skip-download")
        }
        let r = try await ProcessRunner.run(legendary, args, environment: environment)
        guard r.succeeded else { throw EpicError.commandFailed("Couldn't sync \(game.title)'s cloud saves.") }
    }
}

public extension GOGProvider {
    struct CloudLocation: Equatable, Sendable {
        public let name: String
        public let location: String
    }

    /// The game's Galaxy client id, from its `goggame-<id>.info` (games with cloud saves have one).
    func clientID(_ game: Game) -> String? {
        guard let folder = loadInstalled().games[game.storeID]?.path,
              let data = try? Data(contentsOf: folder.appendingPathComponent("goggame-\(game.storeID).info")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["clientId"] as? String, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return id
    }

    /// Where Galaxy keeps the game's cloud saves on Windows (GOG's remote config), as Heroic reads it.
    func cloudLocations(clientID: String) async -> [CloudLocation] {
        guard let url = URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.cloudLocations(remoteConfig: data, clientID: clientID)
    }

    static func cloudLocations(remoteConfig data: Data, clientID: String) -> [CloudLocation] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let windows = content["Windows"] as? [String: Any],
              let storage = windows["cloudStorage"] as? [String: Any],
              storage["enabled"] as? Bool == true else { return [] }
        let locations = (storage["locations"] as? [[String: Any]] ?? []).compactMap { entry -> CloudLocation? in
            guard let name = entry["name"] as? String, let location = entry["location"] as? String else { return nil }
            return CloudLocation(name: name, location: location)
        }
        // Enabled without locations: Galaxy's own default folder.
        return locations.isEmpty
            ? [CloudLocation(name: "__default", location: "<?APPLICATION_DATA_LOCAL?>/GOG.com/Galaxy/Applications/\(clientID)/Storage/Shared/Files")]
            : locations
    }

    /// Syncs each cloud location with GOG. `timestamps` are the last sync times by location name (from the previous
    /// call); the new ones come back.
    func syncSaves(_ game: Game, bottle: Bottle, timestamps: [String: String], direction: CloudSavePath.Direction = .both) async throws -> [String: String] {
        guard bottle.exists else { throw GOGError.failed("Start \(game.title) once first, so its saves have a place to go.") }
        guard isSignedIn, let install = loadInstalled().games[game.storeID]?.path, let client = clientID(game) else {
            throw GOGError.failed("\(game.title) has no cloud saves.")
        }
        let locations = await cloudLocations(clientID: client)
        guard !locations.isEmpty else { throw GOGError.failed("\(game.title) has no cloud saves.") }
        var result = timestamps
        for location in locations {
            guard let folder = CloudSavePath.gog(location: location.location, bottle: bottle, installPath: install) else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var args = ["--auth-config-path", authFile.path, "save-sync", folder.path, game.storeID, "--os", "windows",
                        "--ts", timestamps[location.name] ?? "0", "--name", location.name]
            switch direction {
            case .both: break
            case .download: args.append("--skip-upload")
            case .upload: args.append("--skip-download")
            }
            let lastOut = LastLine()
            let r = try await ProcessRunner.run(gogdl, args, environment: environment) { line in
                if case .stdout(let text) = line { lastOut.set(text) }   // gogdl logs to stderr
            }
            guard r.succeeded else { throw GOGError.failed("Couldn't sync \(game.title)'s cloud saves.") }
            // gogdl prints the new sync time on stdout.
            if let last = lastOut.value?.trimmingCharacters(in: .whitespaces), Double(last) != nil {
                result[location.name] = last
            }
        }
        return result
    }
}

private final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ s: String) { lock.lock(); if !s.trimmingCharacters(in: .whitespaces).isEmpty { line = s }; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return line }
}
