import Foundation

/// What a game needs to run well, applied automatically before it starts: Microsoft runtimes, DLL load order,
/// environment, arguments, a graphics backend. Recipes are data, published in UniveEngine's repository
/// (`engine/recipes.json`) so a fix for one game reaches everyone without an app update, and anyone can propose one.
public struct GameRecipe: Codable, Equatable, Sendable {
    public var components: [WindowsComponent]?
    /// `name=n,b` entries for `WINEDLLOVERRIDES`.
    public var dllOverrides: [String]?
    public var environment: [String: String]?
    public var arguments: [String]?
    public var backend: GraphicsBackend?
    /// Why (English), shown on the game page.
    public var note: String?

    public init(components: [WindowsComponent]? = nil, dllOverrides: [String]? = nil, environment: [String: String]? = nil,
                arguments: [String]? = nil, backend: GraphicsBackend? = nil, note: String? = nil) {
        self.components = components
        self.dllOverrides = dllOverrides
        self.environment = environment
        self.arguments = arguments
        self.backend = backend
        self.note = note
    }

    /// `d3dx9_43=n,b`: DLL names and the load-order letters only.
    public static func isValidOverride(_ entry: String) -> Bool {
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.,-".contains($0)) }
            && parts[1].allSatisfy { "nbd,".contains($0) }
    }

    /// Environment a recipe may set: graphics and Wine tuning only, never anything that changes which programs or
    /// libraries load (`DYLD_*`, `WINEPREFIX`, `WINEDLLPATH`, `PATH`…).
    public static func isAllowedEnvironment(_ key: String) -> Bool {
        let prefixes = ["DXVK_", "D3DM_", "MTL_", "MVK_", "DXMT_", "VKD3D_", "STAGING_", "WINE_D3D_", "WINE_LARGE_ADDRESS_AWARE"]
        return key.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") } && prefixes.contains { key.hasPrefix($0) }
    }

    /// A game flag a recipe may add: `-dx11`, `+set`, `/nolauncher`, `-width=1920`. Never `--anything`: launchers
    /// (Legendary, Steam) read double-dash options themselves, and one like `--wrapper` would run a command.
    public static func isAllowedArgument(_ arg: String) -> Bool {
        guard (2...64).contains(arg.count), let first = arg.first, "-+/".contains(first), !arg.hasPrefix("--") else { return false }
        return arg.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.:=,".contains($0)) }
    }

    /// Flags that take a value. Only these may: a value after anything else could make a game do something rather
    /// than set something (Source runs `+connect <address>` and `+exec <file>` as console commands).
    public static let flagsWithValues: Set<String> = [
        "-force_vendor_id", "-force_device_id", "-w", "-h", "-width", "-height", "-refresh", "-dxlevel",
        "+mat_tonemapping_occlusion_use_stencil", "+mat_hdr_level", "+fps_max",
    ]

    /// Flags that act rather than set, refused even alone: joining a server, running a file, starting another game.
    public static let refusedFlags: Set<String> = ["-applaunch", "+connect", "+exec", "+bind", "+alias", "+map", "+playdemo", "+password"]

    /// A flag's value (`1`, `0x1002`, `1920`): letters, digits and `_.,`, never starting with a dash.
    public static func isAllowedValue(_ value: String) -> Bool {
        (1...32).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.,".contains($0)) }
    }

    /// `arguments` with anything not allowed left out; a value is kept only right after a kept flag that takes one.
    public static func allowedArguments(_ arguments: [String]) -> [String] {
        var kept: [String] = []
        var takesValue = false
        for arg in arguments {
            if isAllowedArgument(arg), !refusedFlags.contains(arg.lowercased()) {
                kept.append(arg)
                takesValue = flagsWithValues.contains(arg.lowercased())
            }
            else if takesValue, isAllowedValue(arg) { kept.append(arg); takesValue = false }
            else { takesValue = false }
        }
        return kept
    }

    /// The recipe with anything it isn't allowed to set left out.
    public var sanitized: GameRecipe {
        var r = self
        r.dllOverrides = dllOverrides?.filter(Self.isValidOverride)
        r.environment = environment?.filter { Self.isAllowedEnvironment($0.key) && !$0.value.contains("\0") }
        r.arguments = arguments.map(Self.allowedArguments)
        return r
    }

    /// `profile` with the recipe applied. The player's own settings win: their backend choice, their environment
    /// values, and their arguments come after the recipe's.
    public func applied(to profile: LaunchProfile) -> LaunchProfile {
        let r = sanitized
        var p = profile
        if p.backend == .auto, let backend = r.backend { p.backend = backend }
        p.dllOverrides = (r.dllOverrides ?? []) + p.dllOverrides
        p.extraEnvironment = (r.environment ?? [:]).merging(p.extraEnvironment) { _, user in user }
        p.extraArguments = (r.arguments ?? []) + p.extraArguments
        return p
    }
}

public struct GameRecipeBook: Codable, Equatable, Sendable {
    /// By library id ("steam:1091500", "epic:…", "gog:…").
    public var recipes: [String: GameRecipe]

    public init(recipes: [String: GameRecipe] = [:]) { self.recipes = recipes }

    public static let url = URL(string: "https://raw.githubusercontent.com/MuratDugan/UniveEngine/main/engine/recipes.json")!

    public func recipe(for gameID: String) -> GameRecipe? { recipes[gameID]?.sanitized }

    public static func decode(_ data: Data) throws -> GameRecipeBook { try JSONDecoder().decode(GameRecipeBook.self, from: data) }
}
