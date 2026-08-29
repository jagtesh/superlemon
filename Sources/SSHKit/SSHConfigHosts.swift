import Foundation

/// Host aliases from the user's OpenSSH client configuration, for the
/// connect picker. Read-only convenience: connecting still hands the alias
/// to `ssh` untouched, so everything in the config (HostName, User, keys,
/// jump hosts) applies whether or not it appeared in this list.
public enum SSHConfigHosts {
    public static func listAliases(
        configPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    ) -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Concrete `Host` aliases in order of appearance; patterns (`*`, `?`)
    /// and negations (`!`) are picker noise and are skipped.
    public static func parse(_ text: String) -> [String] {
        var aliases: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // "Host name1 name2" — keyword is case-insensitive; '=' separator
            // is legal ssh_config syntax too.
            let normalized = line.replacingOccurrences(of: "=", with: " ")
            let fields = normalized.split(whereSeparator: \.isWhitespace)
            guard let keyword = fields.first, keyword.lowercased() == "host" else { continue }
            for name in fields.dropFirst() {
                let alias = String(name)
                guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!"),
                    !aliases.contains(alias)
                else { continue }
                aliases.append(alias)
            }
        }
        return aliases
    }
}
