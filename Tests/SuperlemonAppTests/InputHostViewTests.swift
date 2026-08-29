import AppKit
import SurfaceKit
import Testing

@testable import EditorHostKit

@MainActor
@Suite("InputHostView text input", .serialized)
struct InputHostViewTests {
    private func makeView() -> InputHostView {
        let controller = NvimController()
        let surface = GridSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: FontSpec(name: "Menlo", size: 13))
        return InputHostView(frame: surface.frame, surface: surface, controller: controller)
    }

    @Test func markedAndSelectedRangesAreDocumentCoherent() {
        let view = makeView()
        view.setMarkedText(
            "かな", selectedRange: NSRange(location: 1, length: 1),
            replacementRange: NSRange(location: 4, length: 2))

        #expect(view.hasMarkedText())
        // The host does not pretend an arbitrary Neovim document range is a
        // synchronized text mirror; new compositions use local coordinates.
        #expect(view.markedRange() == NSRange(location: 0, length: 2))
        #expect(view.selectedRange() == NSRange(location: 1, length: 1))
    }

    @Test func utf16ReplacementInsideActiveCompositionPreservesSurroundingText() throws {
        let view = makeView()
        let source = NSMutableAttributedString(string: "A😀B")
        source.addAttribute(
            .markedClauseSegment, value: 0,
            range: NSRange(location: 0, length: source.length))
        view.setMarkedText(
            source, selectedRange: NSRange(location: source.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        // NSString/NSRange counts 😀 as two UTF-16 code units.
        view.setMarkedText(
            "語", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 1, length: 2))

        var actual = NSRange(location: NSNotFound, length: 0)
        let result = try #require(view.attributedSubstring(
            forProposedRange: view.markedRange(), actualRange: &actual))
        #expect(result.string == "A語B")
        #expect(actual == NSRange(location: 0, length: 3))
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func attributedSubstringIntersectsAndReportsActualRange() throws {
        let view = makeView()
        let source = NSMutableAttributedString(string: "変換")
        source.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.thick.rawValue,
            range: NSRange(location: 1, length: 1))
        view.setMarkedText(
            source, selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        var actual = NSRange(location: NSNotFound, length: 0)
        let substring = try #require(view.attributedSubstring(
            forProposedRange: NSRange(location: 1, length: 8), actualRange: &actual))
        #expect(substring.string == "換")
        #expect(actual == NSRange(location: 1, length: 1))
        #expect(
            substring.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
                == NSUnderlineStyle.thick.rawValue)
    }

    @Test func outsideSubstringDoesNotInventDocumentContext() {
        let view = makeView()
        view.setMarkedText(
            "abc", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 10, length: 0))
        #expect(view.attributedSubstring(
            forProposedRange: NSRange(location: 10, length: 3), actualRange: nil) == nil)
        #expect(view.characterIndex(for: NSPoint(x: -100, y: -100)) == NSNotFound)
    }

    @Test func discardClearsWithoutLeavingStaleRanges() {
        let view = makeView()
        view.setMarkedText(
            "compose", selectedRange: NSRange(location: 7, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        view.discardMarkedTextForSessionChange()

        #expect(!view.hasMarkedText())
        #expect(view.markedRange().location == NSNotFound)
        #expect(view.selectedRange().location == NSNotFound)
    }

    @Test func resigningFirstResponderCommitsMarkedTextOnceAndDiscardsIMEComposition() {
        let view = makeView()
        var sentInputs: [String] = []
        var discardCount = 0
        view.commitComposedInput = { sentInputs.append($0) }
        view.discardComposition = { discardCount += 1 }

        view.setMarkedText(
            "にほ", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        _ = view.resignFirstResponder()

        // Exactly one copy travels to Neovim; the IME is told to drop its
        // own buffer so it does not later replay "にほ" on top of whatever
        // it composes next (the duplication bug this guards against).
        #expect(sentInputs == ["にほ"])
        #expect(discardCount == 1)
        #expect(!view.hasMarkedText())
    }

    @Test func acquiringFocusViaMouseDownCommitsMarkedTextOnceAndDiscardsIMEComposition() throws {
        let view = makeView()
        var sentInputs: [String] = []
        var discardCount = 0
        view.commitComposedInput = { sentInputs.append($0) }
        view.discardComposition = { discardCount += 1 }

        view.setMarkedText(
            "かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)

        #expect(sentInputs == ["かな"])
        #expect(discardCount == 1)
        #expect(!view.hasMarkedText())
    }

    @Test func acquiringFocusWithNoMarkedTextDoesNotTouchTheInputContext() throws {
        let view = makeView()
        var discardCount = 0
        view.discardComposition = { discardCount += 1 }

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)

        #expect(discardCount == 0)
    }

    @Test func firstRectReportsCompositionRange() {
        let view = makeView()
        view.setMarkedText(
            "input", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 20, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        _ = view.firstRect(
            forCharacterRange: NSRange(location: 2, length: 1), actualRange: &actual)
        #expect(actual == NSRange(location: 2, length: 1))
    }

    @Test func coordinateLookupAndCandidatePlacementTrackTheSelectedClause() {
        let view = makeView()
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = view
        window.layoutIfNeeded()

        let source = NSMutableAttributedString(string: "かな漢字")
        source.addAttribute(
            .markedClauseSegment, value: 0,
            range: NSRange(location: 0, length: 2))
        source.addAttribute(
            .markedClauseSegment, value: 1,
            range: NSRange(location: 2, length: 2))
        view.setMarkedText(
            source, selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))

        var originActual = NSRange(location: NSNotFound, length: 0)
        let origin = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: &originActual)
        var selectedActual = NSRange(location: NSNotFound, length: 0)
        let selected = view.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &selectedActual)

        #expect(selectedActual == NSRange(location: 2, length: 0))
        #expect(selected.minX > origin.minX)
        let lookup = view.characterIndex(
            for: NSPoint(x: origin.minX + 1, y: origin.midY))
        #expect(lookup != NSNotFound)
        #expect(view.characterIndex(
            for: NSPoint(x: origin.minX - 100, y: origin.midY)) == NSNotFound)
    }
}
