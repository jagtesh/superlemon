// Model -> NSAttributedString mapping tests with a stub highlight resolver.
import AppKit
import Testing
@testable import ChromeKit

/// Stub resolver: hl 0 = black on white; hl 1 = red on yellow; hl 2 = blue
/// on green. Distinct, non-dynamic colors so attribute assertions are exact.
@MainActor
private let stubResolver: HighlightResolver = { hlID in
    switch hlID {
    case 1: return (fg: .red, bg: .yellow)
    case 2: return (fg: .blue, bg: .green)
    default: return (fg: .black, bg: .white)
    }
}

@MainActor
private let testFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

@MainActor
private func fg(of line: NSAttributedString, at location: Int) -> NSColor? {
    line.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
}

@MainActor
private func bg(of line: NSAttributedString, at location: Int) -> NSColor? {
    line.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
}

@MainActor
@Suite struct CmdlineRendererTests {
    @Test func chunksMapToAttributedRuns() {
        let model = CmdlineModel(
            content: [Chunk(hlID: 1, text: "echo"), Chunk(hlID: 2, text: " 42")],
            pos: 7, firstc: ":")
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        // Cursor is past the end, so the text itself is unmodified.
        #expect(line.string == "echo 42 ")
        #expect(fg(of: line, at: 0) == .red)
        #expect(bg(of: line, at: 0) == .yellow)
        #expect(fg(of: line, at: 4) == .blue)
        #expect(bg(of: line, at: 4) == .green)
    }

    @Test func defaultHighlightHasNoBackground() {
        let model = CmdlineModel(content: [Chunk(hlID: 0, text: "plain")], pos: 5)
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(fg(of: line, at: 0) == .black)
        #expect(bg(of: line, at: 0) == nil)
    }

    @Test func blockCursorInvertsCharacterAtPos() {
        let model = CmdlineModel(content: [Chunk(hlID: 0, text: "write")], pos: 2)
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(line.string == "write")
        // Cursor cell: fg = default bg (white), bg = default fg (black).
        #expect(fg(of: line, at: 2) == .white)
        #expect(bg(of: line, at: 2) == .black)
        // Neighbors untouched.
        #expect(fg(of: line, at: 1) == .black)
        #expect(bg(of: line, at: 3) == nil)
    }

    @Test func cursorAtEndAppendsBlock() {
        let model = CmdlineModel(content: [Chunk(hlID: 0, text: "wq")], pos: 2)
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(line.string == "wq ")
        #expect(bg(of: line, at: 2) == .black)
    }

    @Test func specialCharRenderedInvertedAtCursor() {
        let model = CmdlineModel(
            content: [Chunk(hlID: 0, text: "s/")], pos: 2,
            specialChar: SpecialChar(c: "^", shift: false))
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(line.string == "s/^")
        #expect(fg(of: line, at: 2) == .white)
        #expect(bg(of: line, at: 2) == .black)
    }

    @Test func bytePosWithMultibyteContent() {
        // "héllo": h=1 byte, é=2 bytes. pos 3 (bytes) = character index 2.
        let model = CmdlineModel(content: [Chunk(hlID: 0, text: "héllo")], pos: 3)
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(bg(of: line, at: 2) == .black)  // cursor on the first "l"
        #expect(bg(of: line, at: 1) == nil)
    }

    @Test func indentShiftsContentAndCursor() {
        let model = CmdlineModel(content: [Chunk(hlID: 0, text: "echo")], pos: 0, indent: 2)
        let line = CmdlineRenderer.contentLine(for: model, font: testFont, resolver: stubResolver)

        #expect(line.string == "  echo")
        #expect(bg(of: line, at: 2) == .black)  // cursor on "e", after indent
    }

    @Test func utf16OffsetClampsOutOfRange() {
        #expect(CmdlineRenderer.utf16Offset(forUTF8Offset: 99, in: "ab") == 2)
        #expect(CmdlineRenderer.utf16Offset(forUTF8Offset: 0, in: "ab") == 0)
        #expect(CmdlineRenderer.utf16Offset(forUTF8Offset: -1, in: "ab") == 0)
    }

    @Test func blockLinesJoinWithNewlines() {
        let lines = CmdlineRenderer.blockLines(
            [
                [Chunk(hlID: 1, text: "function! Foo()")],
                [Chunk(hlID: 0, text: "  echo 1")],
            ],
            font: testFont, resolver: stubResolver)

        #expect(lines.string == "function! Foo()\n  echo 1")
        #expect(fg(of: lines, at: 0) == .red)
        #expect(fg(of: lines, at: 16) == .black)
    }
}
