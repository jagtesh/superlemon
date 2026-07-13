// GuifontParser — pure parser for nvim's `guifont` option format (DESIGN §4).
//
// Format (`:h gui-font`): a comma-separated fallback list of entries, each
// `Font Name:attr:attr...`. Attributes we care about: `hNN` (point size,
// decimals allowed). Escapes: `\ ` (space), `\,` (comma), `\:`; underscores in
// the name mean spaces (gvim convention, common in dotfiles). The app takes
// the *first* candidate that resolves to a real NSFont — resolution stays out
// of this type so it remains pure and unit-testable without AppKit.

import Foundation

/// One fallback entry parsed from a guifont value.
struct GuifontCandidate: Equatable {
    /// Display/family name with escapes and underscores resolved.
    var name: String
    /// Point size from an `:hNN` attribute, if present.
    var size: Double?
}

enum GuifontParser {
    /// Parse a full guifont value into ordered fallback candidates.
    /// Invalid entries (empty name, `*`) are dropped.
    static func candidates(from guifont: String) -> [GuifontCandidate] {
        splitUnescaped(guifont, separator: ",").compactMap(parseEntry)
    }

    // MARK: - Internals

    private static func parseEntry(_ entry: String) -> GuifontCandidate? {
        let parts = splitUnescaped(entry, separator: ":")
        guard let rawName = parts.first else { return nil }
        let name = unescape(rawName)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "*" else { return nil }

        var size: Double?
        for attribute in parts.dropFirst() {
            let attr = unescape(attribute)
            if attr.hasPrefix("h"), let value = Double(attr.dropFirst()), value > 0 {
                size = value
            }
        }
        return GuifontCandidate(name: name, size: size)
    }

    /// Split on `separator`, honoring backslash escapes (the escape sequences
    /// are preserved in the pieces; `unescape` resolves them later).
    private static func splitUnescaped(_ string: String, separator: Character) -> [String] {
        var pieces: [String] = []
        var current = ""
        var escaped = false
        for character in string {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        pieces.append(current)
        return pieces
    }

    /// Resolve `\x` escape sequences to the literal character.
    private static func unescape(_ string: String) -> String {
        var result = ""
        var escaped = false
        for character in string {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}
