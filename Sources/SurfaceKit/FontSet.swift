import AppKit
import CoreText

/// Resolved font variants + cell metrics for one `FontSpec` (DESIGN §5-6).
/// cellWidth = ceil(advance of "M"); cellHeight = ceil(ascent+descent+leading)
/// + linespace. All grid geometry is these two numbers times cell counts.
struct FontSet {
    enum Variant: UInt8, CaseIterable {
        case regular = 0, bold, italic, boldItalic
        init(bold: Bool, italic: Bool) {
            switch (bold, italic) {
            case (false, false): self = .regular
            case (true, false): self = .bold
            case (false, true): self = .italic
            case (true, true): self = .boldItalic
            }
        }
    }

    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let cellSize: CGSize
    /// The font's true (fractional) monospace advance — cellSize.width is
    /// this ceiled. Glyph positions snap from one to the other (see
    /// GlyphCache): without snapping, run-splits (e.g. visual selection)
    /// re-anchor text and visibly change letter spacing.
    let baseAdvance: CGFloat
    /// Distance from the top edge of a cell down to the text baseline.
    let baselineOffset: CGFloat
    /// Underline geometry from the base font (position is below baseline).
    let underlineOffset: CGFloat
    let underlineThickness: CGFloat
    /// Rendering flags carried from the FontSpec (see FontSpec docs).
    let powerlineGlyphs: Bool
    let ligatures: Bool
    /// The SYMBOL COMPANION font: ligature sequences shape through this
    /// (real calt ligatures, e.g. bundled Fira Code) while all text keeps
    /// the user's font. nil = no ligature-capable font available; the
    /// Unicode-substitution fallback applies.
    let symbolFont: CTFont?
    /// The symbol font's own monospace advance — needed to map its shaped
    /// positions onto the main font's cell grid.
    let symbolBaseAdvance: CGFloat

    /// Known ligature-capable monospace fonts, preferred order. The bundled
    /// runtime/fonts/ directory is registered at app launch, so FiraCode
    /// resolves even when not user-installed.
    static let symbolFontCandidates = [
        "FiraCodeNFM-Reg",  // bundled FiraCode Nerd Font Mono (runtime/fonts/)
        "FiraCode-Regular", "JetBrainsMono-Regular", "CascadiaCode-Regular",
        "MonaspaceNeon-Regular", "Hasklig-Regular",
    ]
    /// Carried from the spec: force built-in fallback rendering.
    let forceSynthesis: Bool

    init(spec: FontSpec) {
        let base = spec.name.flatMap { NSFont(name: $0, size: spec.size) }
            ?? NSFont.monospacedSystemFont(ofSize: spec.size, weight: .regular)
        let ct = base as CTFont
        regular = ct
        bold = Self.variant(of: ct, traits: .boldTrait)
        italic = Self.variant(of: ct, traits: .italicTrait)
        boldItalic = Self.variant(of: ct, traits: [.boldTrait, .italicTrait])

        var chars: [UniChar] = [0x4D]  // "M"
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyphs, &advance, 1)

        let ascent = CTFontGetAscent(ct)
        let descent = CTFontGetDescent(ct)
        let leading = CTFontGetLeading(ct)
        powerlineGlyphs = spec.powerlineGlyphs
        ligatures = spec.ligatures
        forceSynthesis = spec.forceSynthesis
        var symbol: CTFont? = nil
        if spec.useSymbolFont {
            for name in Self.symbolFontCandidates {
                if let font = NSFont(name: name, size: spec.size) {
                    symbol = font as CTFont
                    break
                }
            }
        }
        symbolFont = symbol
        if let symbol {
            var symChars: [UniChar] = [0x4D]
            var symGlyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(symbol, &symChars, &symGlyphs, 1)
            var symAdvance = CGSize.zero
            CTFontGetAdvancesForGlyphs(symbol, .horizontal, &symGlyphs, &symAdvance, 1)
            symbolBaseAdvance = max(1, symAdvance.width)
        } else {
            symbolBaseAdvance = 1
        }
        baseAdvance = max(1, advance.width)
        cellSize = CGSize(
            width: max(1, ceil(advance.width)),
            height: max(1, ceil(ascent + descent + leading) + spec.linespace))
        baselineOffset = spec.linespace / 2 + ceil(ascent)
        underlineOffset = max(1, -CTFontGetUnderlinePosition(ct))
        underlineThickness = max(1, CTFontGetUnderlineThickness(ct))
    }

    func font(for variant: Variant) -> CTFont {
        switch variant {
        case .regular: return regular
        case .bold: return bold
        case .italic: return italic
        case .boldItalic: return boldItalic
        }
    }

    /// Trait variant, falling back to the base font when the family lacks it.
    private static func variant(of font: CTFont, traits: CTFontSymbolicTraits) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
    }
}
