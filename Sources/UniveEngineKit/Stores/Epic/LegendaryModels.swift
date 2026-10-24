import Foundation

/// Decoders for `legendary list --json` and `legendary list-installed --json`.
struct LegendaryListEntry: Decodable {
    struct Metadata: Decodable {
        struct KeyImage: Decodable { let type: String; let url: String }
        let keyImages: [KeyImage]?
    }
    struct AssetInfo: Decodable { let build_version: String? }
    let app_name: String
    let app_title: String
    let metadata: Metadata?
    let asset_infos: [String: AssetInfo]?
}

struct LegendaryInstalledEntry: Decodable {
    let app_name: String
    let title: String?
    let install_path: String
    let install_size: Int64?
    let version: String?
}

public enum LegendaryParser {
    public static func games(listJSON: Data, installedJSON: Data) throws -> [Game] {
        let decoder = JSONDecoder()
        let owned = try decoder.decode([LegendaryListEntry].self, from: listJSON)
        let installed = Dictionary(
            uniqueKeysWithValues: try decoder.decode([LegendaryInstalledEntry].self, from: installedJSON).map { ($0.app_name, $0) })

        func image(_ e: LegendaryListEntry, _ types: [String]) -> URL? {
            for t in types { if let u = e.metadata?.keyImages?.first(where: { $0.type == t })?.url { return URL(string: u) } }
            return nil
        }
        return owned.map { e in
            let inst = installed[e.app_name]
            return Game(
                store: .epic, storeID: e.app_name, title: e.app_title, isInstalled: inst != nil,
                installPath: inst.map { URL(fileURLWithPath: $0.install_path) },
                sizeOnDisk: inst?.install_size,
                coverURL: image(e, ["DieselGameBoxTall", "Thumbnail"]),
                heroURL: image(e, ["DieselGameBox", "OfferImageWide"]))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Installed games whose Windows build in the store differs from the installed one.
    public static func updates(listJSON: Data, installedJSON: Data) -> Set<String> {
        let decoder = JSONDecoder()
        guard let owned = try? decoder.decode([LegendaryListEntry].self, from: listJSON),
              let installed = try? decoder.decode([LegendaryInstalledEntry].self, from: installedJSON) else { return [] }
        let latest = Dictionary(owned.compactMap { e in e.asset_infos?["Windows"]?.build_version.map { (e.app_name, $0) } }) { a, _ in a }
        return Set(installed.compactMap { i in
            guard let have = i.version, let newest = latest[i.app_name], newest != have else { return nil }
            return i.app_name
        })
    }

    /// Parses legendary's download progress line, e.g. `[DLManager] INFO: = Progress: 12.34% (123/1000), Running for ...`.
    public static func progress(from line: String) -> Double? {
        guard let range = line.range(of: "Progress: ") else { return nil }
        let rest = line[range.upperBound...]
        guard let pct = rest.split(separator: "%").first, let value = Double(pct) else { return nil }
        return min(1, max(0, value / 100))
    }
}
