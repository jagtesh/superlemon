// ChromeState event-application tests: headless, no AppKit views involved.
import Testing
import NvimKit
@testable import ChromeKit

/// Shorthand: one single-chunk styled content array.
func chunks(_ text: String, hl: Int = 0) -> [StyledChunk] {
    [(hlID: hl, text: text)]
}

func batch(_ events: UIEvent...) -> RedrawBatch {
    RedrawBatch(events: events)
}

@MainActor
@Suite struct ChromeStateCmdlineTests {
    @Test func showSetsModel() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("write"), pos: 5, firstc: ":", prompt: "", indent: 0, level: 1)))

        let model = try! #require(state.cmdline)
        #expect(model.text == "write")
        #expect(model.pos == 5)
        #expect(model.firstc == ":")
        #expect(model.level == 1)
        #expect(model.specialChar == nil)
    }

    @Test func posUpdatesCursorOnly() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("write"), pos: 5, firstc: ":", prompt: "", indent: 0, level: 1)))
        state.apply(batch(.cmdlinePos(pos: 2, level: 1)))

        #expect(state.cmdline?.pos == 2)
        #expect(state.cmdline?.text == "write")
    }

    @Test func hideClearsModel() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("x"), pos: 1, firstc: ":", prompt: "", indent: 0, level: 1)))
        state.apply(batch(.cmdlineHide(level: 1)))

        #expect(state.cmdline == nil)
    }

    @Test func levelStacking() {
        // q: opens the cmdwin (level 1 cmdline), then : inside opens level 2.
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("history"), pos: 0, firstc: ":", prompt: "", indent: 0, level: 1)))
        state.apply(batch(.cmdlineShow(
            content: chunks("nested"), pos: 0, firstc: "=", prompt: "", indent: 0, level: 2)))

        #expect(state.cmdline?.text == "nested")
        #expect(state.cmdline?.level == 2)

        // Hiding the inner level restores the outer one, content intact.
        state.apply(batch(.cmdlineHide(level: 2)))
        #expect(state.cmdline?.text == "history")
        #expect(state.cmdline?.level == 1)

        state.apply(batch(.cmdlineHide(level: 1)))
        #expect(state.cmdline == nil)
    }

    @Test func posTargetsItsLevel() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("outer"), pos: 0, firstc: ":", prompt: "", indent: 0, level: 1)))
        state.apply(batch(.cmdlineShow(
            content: chunks("inner"), pos: 0, firstc: ":", prompt: "", indent: 0, level: 2)))
        state.apply(batch(.cmdlinePos(pos: 3, level: 1)))

        // Visible (level 2) cmdline is untouched.
        #expect(state.cmdline?.pos == 0)
        state.apply(batch(.cmdlineHide(level: 2)))
        #expect(state.cmdline?.pos == 3)
    }

    @Test func blockMode() {
        let state = ChromeState()
        state.apply(batch(
            .cmdlineBlockShow(lines: [chunks("function! Foo()")]),
            .cmdlineShow(
                content: chunks("echo 1"), pos: 6, firstc: ":", prompt: "", indent: 2, level: 1)
        ))
        #expect(state.cmdline?.blockLines.count == 1)
        #expect(state.cmdline?.indent == 2)

        state.apply(batch(.cmdlineBlockAppend(line: chunks("  echo 1"))))
        #expect(state.cmdline?.blockLines.count == 2)
        #expect(state.cmdline?.blockLines[1].joinedText == "  echo 1")

        state.apply(batch(.cmdlineBlockHide))
        #expect(state.cmdline?.blockLines.isEmpty == true)
    }

    @Test func specialCharPendingAndClearedByNextShow() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("s/"), pos: 2, firstc: ":", prompt: "", indent: 0, level: 1)))
        state.apply(batch(.cmdlineSpecialChar(c: "^", shift: false, level: 1)))

        #expect(state.cmdline?.specialChar == SpecialChar(c: "^", shift: false))

        // The next cmdline_show (nvim resends after the literal is typed)
        // clears the pending special char.
        state.apply(batch(.cmdlineShow(
            content: chunks("s/\u{1}"), pos: 3, firstc: ":", prompt: "", indent: 0, level: 1)))
        #expect(state.cmdline?.specialChar == nil)
    }

    @Test func promptStyleInput() {
        let state = ChromeState()
        state.apply(batch(.cmdlineShow(
            content: chunks("y"), pos: 1, firstc: "", prompt: "Save? ", indent: 0, level: 1)))
        #expect(state.cmdline?.prompt == "Save? ")
        #expect(state.cmdline?.firstc == "")
    }
}

@MainActor
@Suite struct ChromeStatePopupMenuTests {
    private static let items = [
        PopupMenuItem(word: "append", kind: "f"),
        PopupMenuItem(word: "applyBatch", kind: "f"),
        PopupMenuItem(word: "array", kind: "v"),
    ]

    @Test func showSelectHide() {
        let state = ChromeState()
        state.apply(batch(.popupmenuShow(items: Self.items, selected: -1, row: 4, col: 10, grid: 2)))

        let menu = try! #require(state.popupmenu)
        #expect(menu.items.count == 3)
        #expect(menu.selected == -1)
        #expect(menu.row == 4 && menu.col == 10 && menu.grid == 2)

        state.apply(batch(.popupmenuSelect(selected: 1)))
        #expect(state.popupmenu?.selected == 1)
        // Selection change must not disturb items/anchor.
        #expect(state.popupmenu?.items == Self.items)
        #expect(state.popupmenu?.row == 4)

        state.apply(batch(.popupmenuHide))
        #expect(state.popupmenu == nil)
    }

    @Test func selectionClampsHigh() {
        let state = ChromeState()
        state.apply(batch(.popupmenuShow(items: Self.items, selected: 99, row: 0, col: 0, grid: 2)))
        #expect(state.popupmenu?.selected == 2)

        state.apply(batch(.popupmenuSelect(selected: 42)))
        #expect(state.popupmenu?.selected == 2)
    }

    @Test func selectionClampsNegativeToNone() {
        let state = ChromeState()
        state.apply(batch(.popupmenuShow(items: Self.items, selected: 0, row: 0, col: 0, grid: 2)))
        state.apply(batch(.popupmenuSelect(selected: -5)))
        #expect(state.popupmenu?.selected == -1)
    }

    @Test func selectWithoutMenuIsIgnored() {
        let state = ChromeState()
        var changes = 0
        state.onChange = { changes += 1 }
        state.apply(batch(.popupmenuSelect(selected: 3)))

        #expect(state.popupmenu == nil)
        #expect(changes == 0)
    }
}

@MainActor
@Suite struct ChromeStateMessageTests {
    @Test func showAppends() {
        let state = ChromeState()
        state.apply(batch(.msgShow(kind: "echo", content: chunks("hello"), replaceLast: false)))
        state.apply(batch(.msgShow(kind: "emsg", content: chunks("E492"), replaceLast: false)))

        #expect(state.messages.count == 2)
        #expect(state.messages[0].text == "hello")
        #expect(state.messages[1].isError)
    }

    @Test func replaceLastReplacesMostRecent() {
        let state = ChromeState()
        state.apply(batch(.msgShow(kind: "echo", content: chunks("first"), replaceLast: false)))
        state.apply(batch(.msgShow(kind: "echo", content: chunks("second"), replaceLast: false)))
        state.apply(batch(.msgShow(kind: "echo", content: chunks("replacement"), replaceLast: true)))

        #expect(state.messages.count == 2)
        #expect(state.messages[0].text == "first")
        #expect(state.messages[1].text == "replacement")
    }

    @Test func replaceLastOnEmptyAppends() {
        let state = ChromeState()
        state.apply(batch(.msgShow(kind: "echo", content: chunks("only"), replaceLast: true)))
        #expect(state.messages.count == 1)
    }

    @Test func clearEmpties() {
        let state = ChromeState()
        state.apply(batch(.msgShow(kind: "echo", content: chunks("x"), replaceLast: false)))
        state.apply(batch(.msgClear))
        #expect(state.messages.isEmpty)
    }

    @Test func confirmDetection() {
        let state = ChromeState()
        state.apply(batch(.msgShow(
            kind: "confirm", content: chunks("Save changes to \"a.txt\"?"), replaceLast: false)))

        let confirm = try! #require(state.pendingConfirm)
        #expect(confirm.needsPrompt)
        #expect(state.messages.last?.needsPrompt == true)

        state.clearPendingConfirm()
        #expect(state.pendingConfirm == nil)
    }

    @Test func confirmClearedByMsgClear() {
        let state = ChromeState()
        state.apply(batch(.msgShow(kind: "confirm", content: chunks("?"), replaceLast: false)))
        state.apply(batch(.msgClear))
        #expect(state.pendingConfirm == nil)
    }

    @Test func showmodeShowcmdRulerSeparateFromMessages() {
        let state = ChromeState()
        state.apply(batch(
            .msgShowmode(content: chunks("-- INSERT --")),
            .msgShowcmd(content: chunks("2d")),
            .msgRuler(content: chunks("12,34"))
        ))

        #expect(state.messages.isEmpty)
        #expect(state.showmode.joinedText == "-- INSERT --")
        #expect(state.showcmd.joinedText == "2d")
        #expect(state.ruler.joinedText == "12,34")

        // Mode message clears with empty content, not msg_clear.
        state.apply(batch(.msgShowmode(content: [])))
        #expect(state.showmode.isEmpty)
    }

    @Test func errorKindClassification() {
        for kind in ["emsg", "echoerr", "lua_error", "rpc_error"] {
            #expect(MessageModel(kind: kind, content: []).isError)
        }
        for kind in ["", "echo", "echomsg", "wmsg", "confirm", "quickfix"] {
            #expect(!MessageModel(kind: kind, content: []).isError)
        }
    }
}

@MainActor
@Suite struct ChromeStateTablineAndObservationTests {
    @Test func tablineDecode() {
        let state = ChromeState()
        state.apply(batch(.tablineUpdate(
            currentTab: 1,
            tabs: [
                (handle: Value.int(1), name: "main.swift"),
                (handle: Value.int(2), name: "DESIGN.md"),
            ]
        )))

        #expect(state.tabline.currentTab == 1)
        #expect(state.tabline.tabs == ["main.swift", "DESIGN.md"])
    }

    @Test func onChangeFiresOncePerMutatingBatch() {
        let state = ChromeState()
        var changes = 0
        state.onChange = { changes += 1 }

        // Three chrome mutations in one batch -> exactly one callback.
        state.apply(batch(
            .cmdlineShow(content: chunks("q"), pos: 1, firstc: ":", prompt: "", indent: 0, level: 1),
            .popupmenuShow(items: [PopupMenuItem(word: "quit")], selected: 0, row: 0, col: 0, grid: 2),
            .msgShow(kind: "echo", content: chunks("hi"), replaceLast: false)
        ))
        #expect(changes == 1)

        // A second mutating batch -> a second callback.
        state.apply(batch(.popupmenuHide))
        #expect(changes == 2)
    }

    @Test func onChangeSilentForNonChromeEvents() {
        let state = ChromeState()
        var changes = 0
        state.onChange = { changes += 1 }

        state.apply(batch(
            .gridLine(grid: 1, row: 0, colStart: 0, cells: [CellRun(text: "a", hlID: 0)], wrap: false),
            .gridCursorGoto(grid: 1, row: 0, col: 1),
            .flush
        ))

        #expect(changes == 0)
        #expect(state.cmdline == nil)
        #expect(state.popupmenu == nil)
        #expect(state.messages.isEmpty)
    }

    @Test func onChangeSilentForNoOpChromeEvents() {
        let state = ChromeState()
        state.apply(batch(.popupmenuShow(
            items: [PopupMenuItem(word: "a")], selected: 0, row: 0, col: 0, grid: 2)))

        var changes = 0
        state.onChange = { changes += 1 }

        // Re-selecting the already-selected row, hiding a hidden cmdline,
        // clearing empty messages: all no-ops.
        state.apply(batch(.popupmenuSelect(selected: 0)))
        state.apply(batch(.cmdlineHide(level: 1)))
        state.apply(batch(.msgClear))

        #expect(changes == 0)
    }
}
