// ShellPalette — NORTHSTAR.md §2 measured colors used by ShellKit chrome.
// Light values are pixel-sampled; dark chip colors follow NORTHSTAR §6.3:
// saturated bg + white text in light mode flips to pastel bg + near-black
// text in dark mode.

import AppKit

@MainActor
enum ShellPalette {

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    // Surfaces
    static func surfaceBackground(dark: Bool) -> NSColor { dark ? color(0x1E1E1E) : color(0xFFFFFF) }
    static func hairline(dark: Bool) -> NSColor { dark ? color(0x000000) : color(0xDADADB) }
    static func primaryText(dark: Bool) -> NSColor { dark ? color(0xC7CDD1) : color(0x232323) }
    static func secondaryText(dark: Bool) -> NSColor { dark ? color(0x8B9196) : color(0x7D7E7F) }

    // Quick-open palette (NORTHSTAR §4.3)
    static func paletteBackground(dark: Bool) -> NSColor { dark ? color(0x2A2A2A) : color(0xECECEC) }
    static func paletteField(dark: Bool) -> NSColor { dark ? color(0x1E1E1E) : color(0xFFFFFF) }
    static func paletteSelection(dark: Bool) -> NSColor { dark ? color(0x343434) : color(0xDBDBDB) }
    static func paletteSecondary(dark: Bool) -> NSColor { dark ? color(0x8B9196) : color(0x7D7E7F) }
    static func paletteTertiary(dark: Bool) -> NSColor { dark ? color(0x6E6E6F) : color(0xA9A9AA) }

    // Sidebar
    static func sidebarSelection(dark: Bool) -> NSColor { dark ? color(0x343434) : color(0xEAEAEA) }

    // Titlebar band + buffer tab strip (NORTHSTAR §2.1/§2.2 titlebar.bg,
    // §4.1 item 2). Active tab pops off the band toward the editor surface;
    // inactive labels use the measured tab-strip gray.
    static func titlebarBackground(dark: Bool) -> NSColor { dark ? color(0x373736) : color(0xF0F0EE) }
    static func tabActiveBackground(dark: Bool) -> NSColor { dark ? color(0x4A4A49) : color(0xFFFFFF) }
    static func tabActiveText(dark: Bool) -> NSColor { dark ? color(0xCDD2D7) : color(0x3A3A3A) }
    static func tabInactiveText(dark: Bool) -> NSColor { dark ? color(0xA6ABB0) : color(0xA2A3A5) }

    // Status bar chips (NORTHSTAR §2.1/§2.2 + §6.3 chip flip)
    static func statusChipBackground(dark: Bool) -> NSColor { dark ? color(0x2F3336) : color(0xE2E3E5) }
    static func statusChipText(dark: Bool) -> NSColor { dark ? color(0xC7CDD1) : color(0x232323) }
    static func lineColBackground(dark: Bool) -> NSColor { dark ? color(0xADC694) : color(0x005A37) }
    static func lineColText(dark: Bool) -> NSColor { dark ? color(0x1B1F16) : color(0xFFFFFF) }

    /// Mode badge colors. Light: saturated bg + white text (NORMAL measured
    /// #004DC8). Dark: desaturated pastel bg + near-black text (NORMAL
    /// measured ≈#66788A slate; the others are derived pastels in the same
    /// family: sage / lilac / apricot).
    static func modeBadge(_ mode: StatusMode, dark: Bool) -> (background: NSColor, text: NSColor) {
        if dark {
            let bg: UInt32
            switch mode {
            case .normal: bg = 0x66788A   // slate (measured)
            case .insert: bg = 0x9BC49B   // sage pastel
            case .visual: bg = 0xB9A3D0   // lilac pastel
            case .command: bg = 0xD9B48A  // apricot pastel
            case .replace: bg = 0xC79595  // dusty rose (measured project accent)
            }
            return (color(bg), color(0x1B1F16))
        } else {
            let bg: UInt32
            switch mode {
            case .normal: bg = 0x004DC8   // measured
            case .insert: bg = 0x1E7B34   // green
            case .visual: bg = 0x6F42C1   // purple
            case .command: bg = 0xC2570A  // orange
            case .replace: bg = 0xB3261E  // red
            }
            return (color(bg), .white)
        }
    }

    // Git badges (superlemon.git): NERDTree-git conventions, pastel in dark.
    static func gitModified(dark: Bool) -> NSColor { dark ? color(0xE0B268) : color(0xB2621B) }
    static func gitAdded(dark: Bool) -> NSColor { dark ? color(0xADC694) : color(0x107C10) }
    static func gitDeleted(dark: Bool) -> NSColor { dark ? color(0xC79595) : color(0xC42B1C) }
    static func gitRenamed(dark: Bool) -> NSColor { dark ? color(0xB4A7D6) : color(0x8E24AA) }
    static func gitUntracked(dark: Bool) -> NSColor { dark ? color(0x8B9196) : color(0x7D7E7F) }

    // File-type dot colors for the sidebar (small fixed palette).
    static func fileTypeColor(forExtension ext: String, dark: Bool) -> NSColor {
        switch ext.lowercased() {
        case "swift": return color(0xF05138)          // swift orange
        case "js", "jsx", "mjs", "cjs": return color(0xE8C032) // js yellow
        case "md", "markdown": return color(0x2F6BD5) // md blue
        case "json": return color(0x3D9950)           // json green
        default: return dark ? color(0x8B9196) : color(0xA2A3A5)
        }
    }
}
