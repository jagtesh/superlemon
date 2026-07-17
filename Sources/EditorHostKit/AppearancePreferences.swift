import AppKit

/// How the editor's light/dark theme is chosen. Auto reports the macOS
/// system appearance to Neovim's 'background' (the UI-detection role
/// `:h 'background'` describes); Light/Dark force a value regardless of
/// the system. Neovim remains the pixel authority either way — a
/// colorscheme that ignores 'background' keeps its own colors.
public enum AppearanceMode: String, CaseIterable, Sendable {
    case auto
    case light
    case dark

    public var displayName: String {
        switch self {
        case .auto: "Auto (match system)"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The 'background' value to report and whether the report may override
    /// an explicit user 'background' (Settings choices do; Auto does not).
    public func resolvedBackground(systemIsDark: Bool) -> (value: String, force: Bool) {
        switch self {
        case .auto: (systemIsDark ? "dark" : "light", false)
        case .light: ("light", true)
        case .dark: ("dark", true)
        }
    }
}

/// UserDefaults adapter. Appearance is a GUI-side preference like the
/// configuration source (it must exist before any Vim file has run), so it
/// lives beside `NvimConfigPreferences` rather than in the Vim files.
public enum AppearancePreferences {
    static let modeKey = "AppearanceMode"

    public static func load(from defaults: UserDefaults = .standard) -> AppearanceMode {
        defaults.string(forKey: modeKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .auto
    }

    public static func save(
        _ mode: AppearanceMode, to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
