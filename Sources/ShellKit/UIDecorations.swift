// superlemon.ui support types (runtime/CONTRACT.md "superlemon.ui",
// DESIGN §15): the pure, testable half of the GUI-side component router —
// "#RRGGBB" color parsing and namespace-scoped sidebar decoration
// composition. The router itself (payload decode + dispatch plumbing)
// lives in SuperlemonApp; everything with logic worth testing is here.

import AppKit

// MARK: - "#RRGGBB" parsing

/// Colors cross the superlemon.ui wire as `"#RRGGBB"` strings.
public enum UIColorHex {
    /// `"#RRGGBB"` (case-insensitive; the leading `#` is required by the
    /// contract but tolerated absent) → sRGB NSColor. nil for anything
    /// malformed — callers drop the color rather than crash.
    public static func parse(_ string: String) -> NSColor? {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit),
            let value = UInt32(hex, radix: 16)
        else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Sidebar decorations

/// One `superlemon.ui sidebar` decoration: a trailing text badge
/// (`set_badge`) or a colored dot (`set_dot`).
public struct SidebarDecoration: Equatable {
    public enum Kind: Equatable {
        /// Trailing badge text (e.g. "M", "3●").
        case badge(String)
        /// A plain colored dot ("●").
        case dot
    }

    public var kind: Kind
    /// nil = the sidebar's default badge color.
    public var color: NSColor?

    public init(kind: Kind, color: NSColor? = nil) {
        self.kind = kind
        self.color = color
    }
}

/// Namespace-isolated decoration state (`[namespace: [path: Decoration]]`)
/// with deterministic composition per the contract: namespaces are composed
/// SORTED BY NAME, later (lexicographically greater) namespaces winning per
/// path; a namespace's `clear` never touches another namespace's state.
public struct SidebarDecorationStore {
    private var namespaces: [String: [String: SidebarDecoration]] = [:]

    public init() {}

    /// Sets (or replaces) `namespace`'s decoration for `path`.
    /// Paths are opaque keys — the embedder resolves cwd-relative wire
    /// paths to absolute ones before storing.
    public mutating func set(
        _ decoration: SidebarDecoration, path: String, namespace: String
    ) {
        namespaces[namespace, default: [:]][path] = decoration
    }

    /// Drops every decoration owned by `namespace` — and nothing else.
    public mutating func clear(namespace: String) {
        namespaces.removeValue(forKey: namespace)
    }

    /// The composed path → decoration map (sorted-by-name, later wins).
    public var composed: [String: SidebarDecoration] {
        var result: [String: SidebarDecoration] = [:]
        for name in namespaces.keys.sorted() {
            for (path, decoration) in namespaces[name] ?? [:] {
                result[path] = decoration
            }
        }
        return result
    }
}
