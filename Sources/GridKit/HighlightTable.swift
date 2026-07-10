import NvimKit

/// Fully resolved drawing attributes: defaults applied, `reverse` folded in.
/// The renderer uses these colors directly and never re-implements fallback.
public struct ResolvedAttrs: Sendable, Equatable {
    public var foreground: RGBColor
    public var background: RGBColor
    public var special: RGBColor
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var underline = false
    public var undercurl = false
    public var underdouble = false
    public var underdotted = false
    public var underdashed = false
    public var blend: Int = 0

    public init(foreground: RGBColor, background: RGBColor, special: RGBColor) {
        self.foreground = foreground
        self.background = background
        self.special = special
    }
}

/// The highlight table: id -> attrs from `hl_attr_define`, default colors from
/// `default_colors_set`, and the semantic-name -> id map from `hl_group_set`.
public struct HighlightTable: Sendable, Equatable {
    /// Raw attribute entries. id 0 is always the (empty) default entry.
    public private(set) var attributes: [Int: HlAttrs] = [0: HlAttrs()]
    /// Highlight group name -> attribute id (from `hl_group_set`).
    public private(set) var groupIDs: [String: Int] = [:]

    public private(set) var defaultForeground = RGBColor(rgb: 0xFFFFFF)
    public private(set) var defaultBackground = RGBColor(rgb: 0x000000)
    public private(set) var defaultSpecial = RGBColor(rgb: 0xFF0000)

    public init() {}

    public mutating func define(id: Int, attrs: HlAttrs) {
        attributes[id] = attrs
    }

    public mutating func setDefaults(foreground: RGBColor, background: RGBColor, special: RGBColor) {
        defaultForeground = foreground
        defaultBackground = background
        defaultSpecial = special
    }

    public mutating func setGroup(name: String, id: Int) {
        groupIDs[name] = id
    }

    /// Raw attributes for an id; unknown ids resolve to the empty default.
    public func attrs(for id: Int) -> HlAttrs {
        attributes[id] ?? HlAttrs()
    }

    public func id(forGroup name: String) -> Int? {
        groupIDs[name]
    }

    /// Resolve an id to concrete drawing attributes: nil colors fall back to
    /// the defaults, and the `reverse` flag swaps foreground/background so the
    /// renderer never has to.
    public func resolved(id: Int) -> ResolvedAttrs {
        let a = attrs(for: id)
        var fg = a.foreground ?? defaultForeground
        var bg = a.background ?? defaultBackground
        if a.reverse { swap(&fg, &bg) }
        var r = ResolvedAttrs(
            foreground: fg,
            background: bg,
            special: a.special ?? defaultSpecial
        )
        r.bold = a.bold
        r.italic = a.italic
        r.strikethrough = a.strikethrough
        r.underline = a.underline
        r.undercurl = a.undercurl
        r.underdouble = a.underdouble
        r.underdotted = a.underdotted
        r.underdashed = a.underdashed
        r.blend = a.blend
        return r
    }
}
