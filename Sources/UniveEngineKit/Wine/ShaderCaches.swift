import Foundation

/// Compiled-shader caches games build as they run: Metal's (macOS keeps one per program, under Wine's bundle
/// identifiers) and DXVK's state caches next to games. They only save time; clearing them fixes corrupted ones
/// (broken graphics, crashes after a driver or engine update) at the cost of some stutter while they're rebuilt.
public enum ShaderCaches {
    /// Wine engines' bundle identifiers: the Wine Staging builds, and the CrossOver-source builds.
    static let wineBundleIDs = ["org.winehq.wine", "com.codeweavers.CrossOver", "com.codeweavers.CrossOver.wineloader"]
    static let metalFolders = ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver"]

    /// macOS's per-user cache folder (`getconf DARWIN_USER_CACHE_DIR`).
    public static var darwinCacheFolder: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    public static func metalCaches(in root: URL? = darwinCacheFolder) -> [URL] {
        guard let root else { return [] }
        return wineBundleIDs.flatMap { id in metalFolders.map { root.appendingPathComponent("\(id)/\($0)", isDirectory: true) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// DXVK's `*.dxvk-cache` files in the bottles, never following links out of them.
    public static func dxvkCaches(in bottles: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: bottles, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                          options: [.skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            // The enumerator never descends into links; `skipDescendants` here would skip the link's siblings instead.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if url.pathExtension == "dxvk-cache" { found.append(url) }
        }
        return found
    }

    public static func all(paths: Paths) -> [URL] { metalCaches() + dxvkCaches(in: paths.bottles) }

    /// Total bytes of `items` (files and folders).
    public static func size(of items: [URL]) -> Int64 {
        items.reduce(0) { total, url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return total }
            if !isDir.boolValue { return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var sum: Int64 = 0
            while let file = walker?.nextObject() as? URL { sum += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return total + sum
        }
    }

    /// Removes `items`. Call while no game runs: a running one keeps writing its cache.
    @discardableResult
    public static func clear(_ items: [URL]) -> Int64 {
        let freed = size(of: items)
        for url in items { try? FileManager.default.removeItem(at: url) }
        return freed
    }
}
