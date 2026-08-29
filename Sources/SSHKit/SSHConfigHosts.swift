import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Host aliases from the user's OpenSSH client configuration, for the
/// connect picker. Read-only convenience: connecting still hands the alias
/// to `ssh` untouched, so everything in the config (HostName, User, keys,
/// jump hosts) applies whether or not it appeared in this list.
public enum SSHConfigHosts {
    private static let defaultSSHDirectory =
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    private static let maxIncludeDepth = 16

    public static func listAliases(
        configPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    ) -> [String] {
        var aliases: [String] = []
        var visited: Set<String> = []
        let sshDirectory = (configPath as NSString).deletingLastPathComponent
        collectAliases(
            fromFileAt: configPath,
            sshDirectory: sshDirectory.isEmpty ? defaultSSHDirectory : sshDirectory,
            depth: 0, aliases: &aliases, visited: &visited)
        return aliases
    }

    /// Concrete `Host` aliases in order of appearance; patterns (`*`, `?`)
    /// and negations (`!`) are picker noise and are skipped. `Include`
    /// directives are followed too — non-absolute paths resolve against
    /// `baseDirectory` (real ssh_config resolves them against `~/.ssh/`).
    public static func parse(
        _ text: String,
        baseDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
    ) -> [String] {
        var aliases: [String] = []
        var visited: Set<String> = []
        collectAliases(
            fromText: text, sshDirectory: baseDirectory, depth: 0, aliases: &aliases,
            visited: &visited)
        return aliases
    }

    // MARK: - Recursive parse

    private static func collectAliases(
        fromFileAt path: String, sshDirectory: String, depth: Int,
        aliases: inout [String], visited: inout Set<String>
    ) {
        guard depth <= maxIncludeDepth else { return }
        let canonicalPath = (path as NSString).standardizingPath
        guard !visited.contains(canonicalPath) else { return }
        visited.insert(canonicalPath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        collectAliases(
            fromText: text, sshDirectory: sshDirectory, depth: depth, aliases: &aliases,
            visited: &visited)
    }

    private static func collectAliases(
        fromText text: String, sshDirectory: String, depth: Int,
        aliases: inout [String], visited: inout Set<String>
    ) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let tokens = tokenize(line)
            guard let keyword = tokens.first?.lowercased() else { continue }
            let values = Array(tokens.dropFirst())

            if keyword == "host" {
                for name in values {
                    guard !name.contains("*"), !name.contains("?"), !name.hasPrefix("!"),
                        !aliases.contains(name)
                    else { continue }
                    aliases.append(name)
                }
            } else if keyword == "include" {
                for pattern in values {
                    for includedPath in resolveIncludePaths(pattern, sshDirectory: sshDirectory) {
                        collectAliases(
                            fromFileAt: includedPath, sshDirectory: sshDirectory, depth: depth + 1,
                            aliases: &aliases, visited: &visited)
                    }
                }
            }
        }
    }

    /// Splits a config line into keyword + value tokens. Handles the
    /// `Keyword=value` separator form (legal ssh_config syntax) and
    /// double-quoted tokens (so `Host "my server"` is one alias, not two).
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes && (character.isWhitespace || character == "=") {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Resolves an `Include` glob pattern to concrete, sorted file paths.
    /// Relative patterns and `~` resolve against `sshDirectory`.
    private static func resolveIncludePaths(_ pattern: String, sshDirectory: String) -> [String] {
        var expanded = (pattern as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = (sshDirectory as NSString).appendingPathComponent(expanded)
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard glob(expanded, GLOB_TILDE | GLOB_BRACE, nil, &globResult) == 0,
            let pathVector = globResult.gl_pathv
        else { return [] }

        var results: [String] = []
        for index in 0..<Int(globResult.gl_matchc) {
            if let cPath = pathVector[index] {
                results.append(String(cString: cPath))
            }
        }
        return results.sorted()
    }
}
