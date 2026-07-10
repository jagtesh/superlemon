// Pure model -> NSAttributedString rendering for the cmdline palette.
// Kept out of the panel controller so chunk/cursor/special-char mapping is
// testable without any window.
import AppKit

/// Resolves a highlight ID from nvim's highlight table into concrete colors.
/// Injected by the app (backed by GridKit's table) so ChromeKit needs no
/// GridKit dependency. ID 0 must return the default fg/bg pair.
public typealias HighlightResolver = (_ hlID: Int) -> (fg: NSColor, bg: NSColor)

@MainActor
public enum CmdlineRenderer {
    /// Renders the active cmdline content: indent + styled chunks, with a
    /// block cursor at `model.pos` (byte position) and any pending special
    /// char (`<C-v>`) drawn inverted at the cursor.
    ///
    /// Chunk backgrounds are only painted for `hlID != 0` so the panel's own
    /// surface shows through default-styled text.
    public static func contentLine(
        for model: CmdlineModel,
        font: NSFont,
        resolver: HighlightResolver
    ) -> NSAttributedString {
        let defaults = resolver(0)
        let result = NSMutableAttributedString()

        if model.indent > 0 {
            result.append(NSAttributedString(
                string: String(repeating: " ", count: model.indent),
                attributes: [.font: font, .foregroundColor: defaults.fg]
            ))
        }

        for chunk in model.content {
            let colors = resolver(chunk.hlID)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colors.fg,
            ]
            if chunk.hlID != 0 { attrs[.backgroundColor] = colors.bg }
            result.append(NSAttributedString(string: chunk.text, attributes: attrs))
        }

        // Cursor location: pos is a byte offset into the chunk text; the
        // attributed string is indexed in UTF-16. Indent shifts it right.
        let contentText = model.text
        let cursorLocation = model.indent + utf16Offset(forUTF8Offset: model.pos, in: contentText)
        let cursorFG = defaults.bg
        let cursorBG = defaults.fg

        if let special = model.specialChar {
            // Pending <C-v> char renders inverted at the cursor.
            let charString = NSAttributedString(
                string: special.c,
                attributes: [.font: font, .foregroundColor: cursorFG, .backgroundColor: cursorBG]
            )
            result.insert(charString, at: min(cursorLocation, result.length))
        } else if cursorLocation < result.length {
            // Block cursor over an existing grapheme: invert its colors.
            let range = (result.string as NSString).rangeOfComposedCharacterSequence(at: cursorLocation)
            result.addAttributes(
                [.foregroundColor: cursorFG, .backgroundColor: cursorBG],
                range: range
            )
        } else {
            // Cursor past the end: append a block.
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .backgroundColor: cursorBG]
            ))
        }

        return result
    }

    /// Renders block-mode lines (`cmdline_block_*`), newline-joined, shown
    /// above the active line.
    public static func blockLines(
        _ lines: [[Chunk]],
        font: NSFont,
        resolver: HighlightResolver
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            for chunk in line {
                let colors = resolver(chunk.hlID)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: colors.fg,
                ]
                if chunk.hlID != 0 { attrs[.backgroundColor] = colors.bg }
                result.append(NSAttributedString(string: chunk.text, attributes: attrs))
            }
        }
        return result
    }

    /// Converts a UTF-8 byte offset (the ext_cmdline `pos` unit) into a
    /// UTF-16 offset (the NSAttributedString index unit). Out-of-range or
    /// mid-scalar offsets clamp to the end.
    static func utf16Offset(forUTF8Offset byteOffset: Int, in text: String) -> Int {
        guard byteOffset > 0 else { return 0 }
        guard
            let utf8Index = text.utf8.index(
                text.utf8.startIndex, offsetBy: byteOffset, limitedBy: text.utf8.endIndex),
            let stringIndex = utf8Index.samePosition(in: text.utf16)
        else {
            return text.utf16.count
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: stringIndex)
    }
}
