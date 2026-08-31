// superlemon.ui support types (runtime/CONTRACT.md "superlemon.ui",
// DESIGN §15): "#RRGGBB" color parsing for the wire. (Sidebar decoration
// composition moved into the runtime plugin — navbar.lua — with the
// surface-mode navbar.)

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
