import Foundation

/// Neovim initialization sources are mutually exclusive. In particular,
/// user/custom modes never receive Superlemon's managed override afterward.
public enum NvimConfigMode: String, CaseIterable, Sendable {
    case managed
    case user
    case custom

    public var displayName: String {
        switch self {
        case .managed: "Managed by Superlemon"
        case .user: "My Neovim configuration"
        case .custom: "A custom init file"
        }
    }
}

public struct NvimConfigSelection: Equatable, Sendable {
    public init(mode: NvimConfigMode, customInitPath: String?) {
        self.mode = mode
        self.customInitPath = customInitPath
    }

    public var mode: NvimConfigMode
    /// Retained while another mode is selected so switching modes does not
    /// discard a deliberate custom path.
    public var customInitPath: String?
}

/// UserDefaults adapter plus a pure legacy-migration function. The legacy keys
/// remain synchronized temporarily so older app code continues to honor a
/// Settings change while launch selection moves to `NvimLaunchPlan`.
public enum NvimConfigPreferences {
    static let modeKey = "NvimConfigMode"
    static let customInitPathKey = "NvimCustomInitPath"
    static let legacyManagedKey = "UseSuperlemonManagedConfig"
    static let legacyCustomInitPathKey = "CustomInitPath"

    static func migratedSelection(
        modeRawValue: String?,
        legacyManaged: Bool?,
        customInitPath: String?,
        legacyCustomInitPath: String?
    ) -> NvimConfigSelection {
        let savedPath = normalizedPath(customInitPath) ?? normalizedPath(legacyCustomInitPath)
        if let modeRawValue, let mode = NvimConfigMode(rawValue: modeRawValue) {
            return NvimConfigSelection(mode: mode, customInitPath: savedPath)
        }

        if normalizedPath(legacyCustomInitPath) != nil {
            return NvimConfigSelection(mode: .custom, customInitPath: savedPath)
        }
        return NvimConfigSelection(
            mode: legacyManaged == false ? .user : .managed,
            customInitPath: savedPath)
    }

    @discardableResult
    public static func loadAndMigrate(from defaults: UserDefaults = .standard) -> NvimConfigSelection {
        let selection = migratedSelection(
            modeRawValue: defaults.string(forKey: modeKey),
            legacyManaged: defaults.object(forKey: legacyManagedKey) as? Bool,
            customInitPath: defaults.string(forKey: customInitPathKey),
            legacyCustomInitPath: defaults.string(forKey: legacyCustomInitPathKey))
        save(selection, to: defaults)
        return selection
    }

    public static func save(
        _ selection: NvimConfigSelection,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(selection.mode.rawValue, forKey: modeKey)
        if let customPath = normalizedPath(selection.customInitPath) {
            defaults.set(customPath, forKey: customInitPathKey)
        } else {
            defaults.removeObject(forKey: customInitPathKey)
        }

        // Transitional compatibility for launch/menu code that still reads
        // the old independent checkbox and overriding path.
        defaults.set(selection.mode == .managed, forKey: legacyManagedKey)
        if selection.mode == .custom,
            let customPath = normalizedPath(selection.customInitPath)
        {
            defaults.set(customPath, forKey: legacyCustomInitPathKey)
        } else {
            defaults.removeObject(forKey: legacyCustomInitPathKey)
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct NvimLaunchPlan: Equatable, Sendable {
    enum PlanError: LocalizedError, Equatable {
        case executableUnavailable(String)
        case runtimeUnavailable(String)
        case missingManagedConfig(String)
        case missingCustomLoader(String)
        case missingCustomInitPath
        case customInitPathMustBeAbsolute(String)
        case unreadableCustomInit(String)
        case safeStartRequiresManagedMode

        var errorDescription: String? {
            switch self {
            case .executableUnavailable(let path):
                "The selected Neovim executable is missing or not executable: \(path)"
            case .runtimeUnavailable(let path):
                "The bundled Superlemon runtime is missing or unreadable at \(path). Reinstall Superlemon."
            case .missingManagedConfig(let path):
                "The bundled managed configuration is missing at \(path). Reinstall Superlemon."
            case .missingCustomLoader(let path):
                "The bundled custom-config loader is missing at \(path). Reinstall Superlemon."
            case .missingCustomInitPath:
                "Custom configuration is selected, but no init file has been chosen."
            case .customInitPathMustBeAbsolute(let path):
                "The custom init path must be absolute: \(path)"
            case .unreadableCustomInit(let path):
                "The custom init file is missing, unreadable, or not a regular file: \(path)"
            case .safeStartRequiresManagedMode:
                "Safe Start is available only with Superlemon's managed configuration."
            }
        }
    }

    let mode: NvimConfigMode
    let executableURL: URL
    let runtimeURL: URL
    let configURL: URL?
    let arguments: [String]
    let environment: [String: String]
    let safeStart: Bool

    static func make(
        selection: NvimConfigSelection,
        executableURL: URL,
        runtimeURL: URL,
        baseEnvironment: [String: String],
        safeStart: Bool = false,
        isReadableRegularFile: (URL) -> Bool = liveFileValidator,
        isExecutableFile: (URL) -> Bool = liveExecutableValidator
    ) throws -> NvimLaunchPlan {
        if safeStart && selection.mode != .managed {
            throw PlanError.safeStartRequiresManagedMode
        }

        let executableURL = executableURL.standardizedFileURL
        guard isExecutableFile(executableURL) else {
            throw PlanError.executableUnavailable(executableURL.path)
        }

        let runtimeURL = runtimeURL.standardizedFileURL
        let runtimeEntrypoint = runtimeURL.appendingPathComponent("lua/superlemon/init.lua")
        guard isReadableRegularFile(runtimeEntrypoint) else {
            throw PlanError.runtimeUnavailable(runtimeURL.path)
        }

        let configURL: URL?
        let launchInitURL: URL?
        switch selection.mode {
        case .managed:
            let url = runtimeURL.appendingPathComponent("config/init.lua").standardizedFileURL
            guard isReadableRegularFile(url) else {
                throw PlanError.missingManagedConfig(url.path)
            }
            configURL = url
            launchInitURL = url

        case .user:
            configURL = nil
            launchInitURL = nil

        case .custom:
            guard let path = selection.customInitPath?.trimmingCharacters(
                in: .whitespacesAndNewlines), !path.isEmpty
            else { throw PlanError.missingCustomInitPath }
            guard NSString(string: path).isAbsolutePath else {
                throw PlanError.customInitPathMustBeAbsolute(path)
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isReadableRegularFile(url) else {
                throw PlanError.unreadableCustomInit(url.path)
            }
            configURL = url
            let loader = runtimeURL.appendingPathComponent("config/custom-init.lua")
                .standardizedFileURL
            guard isReadableRegularFile(loader) else {
                throw PlanError.missingCustomLoader(loader.path)
            }
            launchInitURL = loader
        }

        var environment = baseEnvironment
        environment["SUPERLEMON_RUNTIME"] = runtimeURL.path
        environment.removeValue(forKey: "SUPERLEMON_SAFE_START")
        environment.removeValue(forKey: "SUPERLEMON_CUSTOM_INIT")
        if selection.mode == .managed {
            environment["NVIM_APPNAME"] = safeStart ? "superlemon-safe" : "superlemon"
        } else if selection.mode == .custom, let configURL {
            environment["SUPERLEMON_CUSTOM_INIT"] = configURL.path
        }
        if safeStart {
            environment["SUPERLEMON_SAFE_START"] = "1"
        }

        var arguments = [
            "--embed",
            "--cmd", "lua vim.opt.runtimepath:prepend(vim.env.SUPERLEMON_RUNTIME)",
        ]
        if let listen = baseEnvironment["SUPERLEMON_LISTEN"], !listen.isEmpty {
            arguments += ["--listen", listen]
        }
        if let launchInitURL {
            arguments += ["-u", launchInitURL.path]
        }

        return NvimLaunchPlan(
            mode: selection.mode,
            executableURL: executableURL,
            runtimeURL: runtimeURL,
            configURL: configURL,
            arguments: arguments,
            environment: environment,
            safeStart: safeStart)
    }

    public static func liveFileValidator(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            fileManager.isReadableFile(atPath: url.path)
        else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func liveExecutableValidator(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Resolves the init file Neovim would use in ordinary (non-managed)
    /// mode without consulting the environment of the currently embedded
    /// process. This matters while Settings is switching from managed mode:
    /// that process has `NVIM_APPNAME=superlemon` and `$MYVIMRC` points at the
    /// bundled baseline, neither of which identifies the user's normal init.
    static func preferredUserInitURL(
        environment: [String: String],
        isRegularFile: (URL) -> Bool = liveFileValidator
    ) -> URL {
        if let myVimrc = environment["MYVIMRC"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !myVimrc.isEmpty
        {
            return URL(
                fileURLWithPath: NSString(string: myVimrc).expandingTildeInPath
            ).standardizedFileURL
        }

        let home = environment["HOME"]?.isEmpty == false
            ? environment["HOME"]!
            : NSHomeDirectory()
        let configRoot = environment["XDG_CONFIG_HOME"]?.isEmpty == false
            ? environment["XDG_CONFIG_HOME"]!
            : URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true).path
        let appName = environment["NVIM_APPNAME"]?.isEmpty == false
            ? environment["NVIM_APPNAME"]!
            : "nvim"
        let root = URL(fileURLWithPath: configRoot, isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
        let lua = root.appendingPathComponent("init.lua")
        let vim = root.appendingPathComponent("init.vim")
        if isRegularFile(lua) { return lua.standardizedFileURL }
        if isRegularFile(vim) { return vim.standardizedFileURL }
        return lua.standardizedFileURL
    }
}
