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
    /// Distance from the top edge of a cell down to the text baseline.
    let baselineOffset: CGFloat
    /// Underline geometry from the base font (position is below baseline).
    let underlineOffset: CGFloat
    let underlineThickness: CGFloat

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
