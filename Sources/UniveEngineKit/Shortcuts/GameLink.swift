import Foundation

/// `univegame://play?game=steam%3A268910`: how a game shortcut asks UniveGame to start a game.
public enum GameLink {
    public static let scheme = "univegame"

    /// `key` is the shortcut's secret: any web page can open a `univegame://` link, so the app starts a game only
    /// for a link that carries the key it gave that game's shortcut, and just shows the game otherwise.
    public static func playURL(gameID: String, key: String? = nil) -> URL? {
        guard isValid(gameID), key.map(isValidKey) ?? true else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "game", value: gameID)] + (key.map { [URLQueryItem(name: "key", value: $0)] } ?? [])
        return components.url
    }

    /// The shortcut key in a play link, if it has a well-formed one.
    public static func key(from url: URL) -> String? {
        guard gameID(from: url) != nil,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              isValidKey(value) else { return nil }
        return value
    }

    /// A new random key: 32 hex characters.
    public static func newKey() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func isValidKey(_ key: String) -> Bool { key.count == 32 && key.allSatisfy(\.isHexDigit) }

    /// The game id in a play link, or nil for anything else.
    public static func gameID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "play",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "game" })?.value, isValid(id) else { return nil }
        return id
    }

    /// "<store>:<id>" with a known store (or "custom", a game the player added) and plain characters in the id.
    public static func isValid(_ id: String) -> Bool {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, StoreKind(rawValue: String(parts[0])) != nil || parts[0] == "custom",
              !parts[1].isEmpty, parts[1].count <= 200 else { return false }
        return parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
