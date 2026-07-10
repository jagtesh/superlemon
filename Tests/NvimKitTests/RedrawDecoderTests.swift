import Testing

@testable import NvimKit

/// Decode a single invocation of one event.
private func decodeOne(_ name: String, _ args: [Value]) -> UIEvent? {
    RedrawDecoder.decode([.array([.string(name), .array(args)])]).events.first
}

/// A Window/Buffer/Tabpage API handle as it appears on the wire: an EXT
/// value whose payload is a msgpack-encoded integer.
private func extHandle(_ id: Int, type: Int8 = 1) -> Value {
    .ext(type: type, data: MsgpackEncoder.encode(.int(Int64(id))))
}

// MARK: - Batch structure

@Suite struct RedrawBatchStructureTests {
    @Test func multipleInvocationsPerEntry() {
        // ["grid_line", args1, args2, ...] — each argsN is one invocation.
        let batch = RedrawDecoder.decode([
            .array([
                .string("grid_cursor_goto"),
                .array([.uint(1), .uint(0), .uint(0)]),
                .array([.uint(2), .uint(5), .uint(7)]),
            ]),
            .array([.string("flush"), .array([])]),
        ])
        #expect(batch.events.count == 3)
        guard case .gridCursorGoto(let grid, let row, let col) = batch.events[1] else {
            Issue.record("expected gridCursorGoto, got \(batch.events[1])")
            return
        }
        #expect((grid, row, col) == (2, 5, 7))
        guard case .flush = batch.events[2] else {
            Issue.record("expected flush")
            return
        }
    }

    @Test func unknownEventsAreSkippedSilently() {
        let batch = RedrawDecoder.decode([
            .array([.string("some_future_event"), .array([.uint(1)])]),
            .array([.string("busy_start"), .array([])]),
        ])
        #expect(batch.events.count == 1)
    }

    @Test func malformedInvocationsAreSkipped() {
        let batch = RedrawDecoder.decode([
            .array([.string("grid_resize"), .array([.string("not-an-int")])]),
            .array([.string("grid_resize"), .array([.uint(1), .uint(80), .uint(24)])]),
        ])
        #expect(batch.events.count == 1)
    }
}

// MARK: - Global events

@Suite struct RedrawGlobalEventTests {
    @Test func setTitleAndIcon() {
        guard case .setTitle("hello.txt")? = decodeOne("set_title", [.string("hello.txt")]),
            case .setIcon("icon")? = decodeOne("set_icon", [.string("icon")])
        else { Issue.record("title/icon mismatch"); return }
    }

    @Test func modeInfoSet() {
        let insertMode: Value = .map([
            (.string("cursor_shape"), .string("vertical")),
            (.string("cell_percentage"), .uint(25)),
            (.string("blinkwait"), .uint(700)),
            (.string("blinkon"), .uint(400)),
            (.string("blinkoff"), .uint(250)),
            (.string("attr_id"), .uint(3)),
            (.string("name"), .string("insert")),
            (.string("short_name"), .string("i")),
        ])
        guard
            case .modeInfoSet(let enabled, let modes)? = decodeOne(
                "mode_info_set", [.bool(true), .array([insertMode])])
        else { Issue.record("expected modeInfoSet"); return }
        #expect(enabled)
        #expect(modes.count == 1)
        #expect(modes[0].cursorShape == .vertical)
        #expect(modes[0].cellPercentage == 25)
        #expect(modes[0].blinkWait == 700)
        #expect(modes[0].blinkOn == 400)
        #expect(modes[0].blinkOff == 250)
        #expect(modes[0].attrID == 3)
        #expect(modes[0].name == "insert")
        #expect(modes[0].shortName == "i")
    }

    @Test func modeChange() {
        guard case .modeChange(mode: "insert", modeIndex: 2)? =
            decodeOne("mode_change", [.string("insert"), .uint(2)])
        else { Issue.record("expected modeChange"); return }
    }

    @Test func optionSet() {
        guard case .optionSet(name: "guifont", value: .string("SF Mono:h13"))? =
            decodeOne("option_set", [.string("guifont"), .string("SF Mono:h13")])
        else { Issue.record("expected optionSet"); return }
    }

    @Test func zeroArgumentEvents() {
        let cases: [(String, (UIEvent) -> Bool)] = [
            ("busy_start", { if case .busyStart = $0 { true } else { false } }),
            ("busy_stop", { if case .busyStop = $0 { true } else { false } }),
            ("mouse_on", { if case .mouseOn = $0 { true } else { false } }),
            ("mouse_off", { if case .mouseOff = $0 { true } else { false } }),
            ("bell", { if case .bell = $0 { true } else { false } }),
            ("visual_bell", { if case .visualBell = $0 { true } else { false } }),
            ("suspend", { if case .suspend = $0 { true } else { false } }),
            ("update_menu", { if case .updateMenu = $0 { true } else { false } }),
            ("flush", { if case .flush = $0 { true } else { false } }),
            ("msg_clear", { if case .msgClear = $0 { true } else { false } }),
            ("popupmenu_hide", { if case .popupmenuHide = $0 { true } else { false } }),
            ("cmdline_block_hide", { if case .cmdlineBlockHide = $0 { true } else { false } }),
        ]
        for (name, matches) in cases {
            guard let event = decodeOne(name, []) else {
                Issue.record("\(name) did not decode")
                continue
            }
            #expect(matches(event), "\(name) decoded to wrong case")
        }
    }

    @Test func chdir() {
        guard case .chdir("/tmp")? = decodeOne("chdir", [.string("/tmp")])
        else { Issue.record("expected chdir"); return }
    }
}

// MARK: - Highlight events

@Suite struct RedrawHighlightEventTests {
    @Test func defaultColorsSet() {
        // [rgb_fg, rgb_bg, rgb_sp, cterm_fg, cterm_bg]
        guard
            case .defaultColorsSet(let fg, let bg, let special)? = decodeOne(
                "default_colors_set",
                [.uint(0xFFFFFF), .uint(0x1E1E1E), .uint(0xFF0000), .uint(0), .uint(0)])
        else { Issue.record("expected defaultColorsSet"); return }
        #expect(fg == RGBColor(rgb: 0xFFFFFF))
        #expect(bg == RGBColor(rgb: 0x1E1E1E))
        #expect(special == RGBColor(rgb: 0xFF0000))
    }

    @Test func hlAttrDefine() {
        let rgbAttrs: Value = .map([
            (.string("foreground"), .uint(0xABCDEF)),
            (.string("background"), .uint(0x123456)),
            (.string("special"), .uint(0x00FF00)),
            (.string("bold"), .bool(true)),
            (.string("italic"), .bool(true)),
            (.string("reverse"), .bool(true)),
            (.string("strikethrough"), .bool(true)),
            (.string("underline"), .bool(true)),
            (.string("undercurl"), .bool(true)),
            (.string("underdouble"), .bool(true)),
            (.string("underdotted"), .bool(true)),
            (.string("underdashed"), .bool(true)),
            (.string("blend"), .uint(30)),
            (.string("altfont"), .bool(true)),  // not in contract: ignored
        ])
        // [id, rgb_attr, cterm_attr, info]
        guard
            case .hlAttrDefine(let id, let attrs)? = decodeOne(
                "hl_attr_define", [.uint(5), rgbAttrs, .map([]), .array([])])
        else { Issue.record("expected hlAttrDefine"); return }
        #expect(id == 5)
        #expect(attrs.foreground == RGBColor(rgb: 0xABCDEF))
        #expect(attrs.background == RGBColor(rgb: 0x123456))
        #expect(attrs.special == RGBColor(rgb: 0x00FF00))
        #expect(attrs.bold && attrs.italic && attrs.reverse && attrs.strikethrough)
        #expect(attrs.underline && attrs.undercurl && attrs.underdouble)
        #expect(attrs.underdotted && attrs.underdashed)
        #expect(attrs.blend == 30)
    }

    @Test func hlAttrDefineAbsentKeysMeanDefaults() {
        guard
            case .hlAttrDefine(_, let attrs)? = decodeOne(
                "hl_attr_define", [.uint(1), .map([]), .map([]), .array([])])
        else { Issue.record("expected hlAttrDefine"); return }
        #expect(attrs.foreground == nil && attrs.background == nil && attrs.special == nil)
        #expect(!attrs.bold && !attrs.underline && attrs.blend == 0)
    }

    @Test func hlGroupSet() {
        guard case .hlGroupSet(name: "Pmenu", id: 12)? =
            decodeOne("hl_group_set", [.string("Pmenu"), .uint(12)])
        else { Issue.record("expected hlGroupSet"); return }
    }
}

// MARK: - Linegrid events

@Suite struct RedrawLinegridEventTests {
    @Test func gridResize() {
        guard case .gridResize(grid: 1, width: 120, height: 40)? =
            decodeOne("grid_resize", [.uint(1), .uint(120), .uint(40)])
        else { Issue.record("expected gridResize"); return }
    }

    @Test func gridClearAndDestroy() {
        guard case .gridClear(grid: 3)? = decodeOne("grid_clear", [.uint(3)]),
            case .gridDestroy(grid: 4)? = decodeOne("grid_destroy", [.uint(4)])
        else { Issue.record("grid clear/destroy mismatch"); return }
    }

    @Test func gridCursorGoto() {
        guard case .gridCursorGoto(grid: 2, row: 10, col: 4)? =
            decodeOne("grid_cursor_goto", [.uint(2), .uint(10), .uint(4)])
        else { Issue.record("expected gridCursorGoto"); return }
    }

    @Test func gridLineHlPersistenceAndRepeat() {
        // ["~", 7] then [" ", <no hl>, 76]: hl 7 must carry over; repeat expands.
        let cells: Value = .array([
            .array([.string("~"), .uint(7)]),
            .array([.string(" "), .uint(7), .uint(76)]),
            .array([.string("x")]),  // still hl 7 (persists when omitted)
            .array([.string("y"), .uint(0)]),
        ])
        guard
            case .gridLine(let grid, let row, let colStart, let runs, let wrap)? = decodeOne(
                "grid_line", [.uint(2), .uint(1), .uint(0), cells, .bool(false)])
        else { Issue.record("expected gridLine"); return }
        #expect((grid, row, colStart, wrap) == (2, 1, 0, false))
        #expect(
            runs == [
                CellRun(text: "~", hlID: 7, repeatCount: 1),
                CellRun(text: " ", hlID: 7, repeatCount: 76),
                CellRun(text: "x", hlID: 7, repeatCount: 1),
                CellRun(text: "y", hlID: 0, repeatCount: 1),
            ])
    }

    @Test func gridLineWrapFlag() {
        guard
            case .gridLine(_, _, _, _, wrap: true)? = decodeOne(
                "grid_line",
                [.uint(1), .uint(0), .uint(79), .array([.array([.string("a"), .uint(0)])]), .bool(true)])
        else { Issue.record("expected wrapped gridLine"); return }
    }

    @Test func gridLineDoubleWidthTrailingEmptyCell() {
        let cells: Value = .array([
            .array([.string("漢"), .uint(0)]),
            .array([.string("")]),  // right half of a double-width char
        ])
        guard
            case .gridLine(_, _, _, let runs, _)? = decodeOne(
                "grid_line", [.uint(1), .uint(0), .uint(0), cells, .bool(false)])
        else { Issue.record("expected gridLine"); return }
        #expect(runs.count == 2)
        #expect(runs[1].text.isEmpty)
    }

    @Test func gridScrollArgumentOrder() {
        // [grid, top, bot, left, right, rows, cols]
        guard
            case .gridScroll(
                grid: 1, top: 2, bottom: 20, left: 0, right: 80, rows: 3, cols: 0)? =
                decodeOne(
                    "grid_scroll",
                    [.uint(1), .uint(2), .uint(20), .uint(0), .uint(80), .int(3), .uint(0)])
        else { Issue.record("expected gridScroll"); return }
    }

    @Test func gridScrollNegativeRows() {
        guard case .gridScroll(_, _, _, _, _, rows: -5, _)? =
            decodeOne(
                "grid_scroll",
                [.uint(1), .uint(0), .uint(10), .uint(0), .uint(80), .int(-5), .uint(0)])
        else { Issue.record("expected negative-rows gridScroll"); return }
    }
}

// MARK: - Multigrid events

@Suite struct RedrawMultigridEventTests {
    @Test func winPosUnwrapsWindowHandle() {
        guard
            case .winPos(grid: 2, win: 1000, startRow: 0, startCol: 0, width: 77, height: 36)? =
                decodeOne(
                    "win_pos",
                    [.uint(2), extHandle(1000), .uint(0), .uint(0), .uint(77), .uint(36)])
        else { Issue.record("expected winPos"); return }
    }

    @Test func winFloatPos() {
        // [grid, win, anchor, anchor_grid, anchor_row, anchor_col,
        //  mouse_enabled, zindex, compindex, screen_row, screen_col]
        guard
            case .winFloatPos(
                grid: 4, win: 1001, anchor: "NW", anchorGrid: 2,
                anchorRow: let row, anchorCol: let col, focusable: true, zIndex: 50)? =
                decodeOne(
                    "win_float_pos",
                    [
                        .uint(4), extHandle(1001), .string("NW"), .uint(2),
                        .float(1.5), .float(10.0), .bool(true), .uint(50),
                        .uint(1), .uint(3), .uint(12),
                    ])
        else { Issue.record("expected winFloatPos"); return }
        #expect(row == 1.5)
        #expect(col == 10.0)
    }

    @Test func winExternalPos() {
        guard case .winExternalPos(grid: 5, win: 1002)? =
            decodeOne("win_external_pos", [.uint(5), extHandle(1002)])
        else { Issue.record("expected winExternalPos"); return }
    }

    @Test func winHideAndClose() {
        guard case .winHide(grid: 3)? = decodeOne("win_hide", [.uint(3)]),
            case .winClose(grid: 3)? = decodeOne("win_close", [.uint(3)])
        else { Issue.record("win hide/close mismatch"); return }
    }

    @Test func msgSetPos() {
        // [grid, row, scrolled, sep_char, zindex, compindex]
        guard case .msgSetPos(grid: 6, row: 22, scrolled: true, sepChar: "─")? =
            decodeOne(
                "msg_set_pos",
                [.uint(6), .uint(22), .bool(true), .string("─"), .uint(200), .uint(2)])
        else { Issue.record("expected msgSetPos"); return }
    }

    @Test func winViewport() {
        guard
            case .winViewport(
                grid: 2, win: 1000, topline: 10, botline: 45, curline: 12, curcol: 3,
                lineCount: 200, scrollDelta: -5)? =
                decodeOne(
                    "win_viewport",
                    [
                        .uint(2), extHandle(1000), .uint(10), .uint(45), .uint(12),
                        .uint(3), .uint(200), .int(-5),
                    ])
        else { Issue.record("expected winViewport"); return }
    }
}

// MARK: - ext_cmdline events

@Suite struct RedrawCmdlineEventTests {
    @Test func cmdlineShow() {
        // [content, pos, firstc, prompt, indent, level, hl_id]
        let content: Value = .array([
            .array([.uint(0), .string("wq")])
        ])
        guard
            case .cmdlineShow(let chunks, pos: 2, firstc: ":", prompt: "", indent: 0, level: 1)? =
                decodeOne(
                    "cmdline_show",
                    [content, .uint(2), .string(":"), .string(""), .uint(0), .uint(1), .uint(0)])
        else { Issue.record("expected cmdlineShow"); return }
        #expect(chunks.count == 1)
        #expect(chunks[0].hlID == 0)
        #expect(chunks[0].text == "wq")
    }

    @Test func cmdlinePos() {
        guard case .cmdlinePos(pos: 5, level: 1)? = decodeOne("cmdline_pos", [.uint(5), .uint(1)])
        else { Issue.record("expected cmdlinePos"); return }
    }

    @Test func cmdlineSpecialChar() {
        guard case .cmdlineSpecialChar(c: "^", shift: true, level: 1)? =
            decodeOne("cmdline_special_char", [.string("^"), .bool(true), .uint(1)])
        else { Issue.record("expected cmdlineSpecialChar"); return }
    }

    @Test func cmdlineHide() {
        // [level, abort]
        guard case .cmdlineHide(level: 2)? = decodeOne("cmdline_hide", [.uint(2), .bool(false)])
        else { Issue.record("expected cmdlineHide"); return }
    }

    @Test func cmdlineBlock() {
        let line: Value = .array([.array([.uint(1), .string("function Foo()")])])
        guard
            case .cmdlineBlockShow(let lines)? = decodeOne("cmdline_block_show", [.array([line])]),
            case .cmdlineBlockAppend(let appended)? = decodeOne("cmdline_block_append", [line])
        else { Issue.record("expected cmdline block events"); return }
        #expect(lines.count == 1)
        #expect(lines[0].count == 1)
        #expect(lines[0][0].text == "function Foo()")
        #expect(lines[0][0].hlID == 1)
        #expect(appended.count == 1)
    }
}

// MARK: - ext_popupmenu / ext_tabline events

@Suite struct RedrawPopupTablineEventTests {
    @Test func popupmenuShow() {
        // [items, selected, row, col, grid]; item [word, kind, menu, info]
        let items: Value = .array([
            .array([.string("foo"), .string("v"), .string("menu"), .string("info")]),
            .array([.string("bar"), .string(""), .string(""), .string("")]),
        ])
        guard
            case .popupmenuShow(let decoded, selected: -1, row: 3, col: 8, grid: 2)? = decodeOne(
                "popupmenu_show", [items, .int(-1), .uint(3), .uint(8), .uint(2)])
        else { Issue.record("expected popupmenuShow"); return }
        #expect(
            decoded == [
                PopupMenuItem(word: "foo", kind: "v", menu: "menu", info: "info"),
                PopupMenuItem(word: "bar"),
            ])
    }

    @Test func popupmenuSelect() {
        guard case .popupmenuSelect(selected: 2)? = decodeOne("popupmenu_select", [.uint(2)])
        else { Issue.record("expected popupmenuSelect"); return }
    }

    @Test func tablineUpdateResolvesCurrentTabIndex() {
        // [curtab, tabs, curbuf, buffers]; curtab is a Tabpage EXT handle.
        let tab1 = extHandle(1, type: 2)
        let tab2 = extHandle(2, type: 2)
        let tabs: Value = .array([
            .map([(.string("tab"), tab1), (.string("name"), .string("one"))]),
            .map([(.string("tab"), tab2), (.string("name"), .string("two"))]),
        ])
        guard
            case .tablineUpdate(currentTab: 1, tabs: let decoded)? = decodeOne(
                "tabline_update", [tab2, tabs, extHandle(1, type: 0), .array([])])
        else { Issue.record("expected tablineUpdate with currentTab 1"); return }
        #expect(decoded.count == 2)
        #expect(decoded[0].name == "one")
        #expect(decoded[1].name == "two")
        #expect(decoded[1].handle == tab2)
    }
}

// MARK: - ext_messages events

@Suite struct RedrawMessageEventTests {
    @Test func msgShow() {
        // [kind, content, replace_last, history, append, id, trigger]
        let content: Value = .array([.array([.uint(9), .string("E486: Pattern not found")])])
        guard
            case .msgShow(kind: "emsg", content: let chunks, replaceLast: false)? = decodeOne(
                "msg_show",
                [.string("emsg"), content, .bool(false), .bool(true), .bool(false), .uint(1)])
        else { Issue.record("expected msgShow"); return }
        #expect(chunks.count == 1)
        #expect(chunks[0].hlID == 9)
        #expect(chunks[0].text == "E486: Pattern not found")
    }

    @Test func msgShowContentTripleForm() {
        // 0.12 content tuples can be [attr_id, text, hl_id]; attr_id wins here.
        let content: Value = .array([.array([.uint(4), .string("hi"), .uint(7)])])
        guard case .msgShow(_, content: let chunks, _)? =
            decodeOne("msg_show", [.string("echo"), content, .bool(false)])
        else { Issue.record("expected msgShow"); return }
        #expect(chunks[0].hlID == 4)
    }

    @Test func msgShowmodeShowcmdRuler() {
        let content: Value = .array([.array([.uint(3), .string("-- INSERT --")])])
        guard case .msgShowmode(content: let mode)? = decodeOne("msg_showmode", [content]),
            case .msgShowcmd(content: _)? = decodeOne("msg_showcmd", [.array([])]),
            case .msgRuler(content: _)? = decodeOne("msg_ruler", [.array([])])
        else { Issue.record("expected showmode/showcmd/ruler"); return }
        #expect(mode.count == 1)
        #expect(mode[0].text == "-- INSERT --")
    }

    @Test func msgHistoryShow() {
        // [entries, prev_cmd]; entry [kind, content, append]
        let entries: Value = .array([
            .array([
                .string("echo"), .array([.array([.uint(0), .string("first")])]), .bool(false),
            ]),
            .array([
                .string("emsg"), .array([.array([.uint(9), .string("second")])]), .bool(false),
            ]),
        ])
        guard case .msgHistoryShow(entries: let decoded)? =
            decodeOne("msg_history_show", [entries, .bool(false)])
        else { Issue.record("expected msgHistoryShow"); return }
        #expect(decoded.count == 2)
        #expect(decoded[0].kind == "echo")
        #expect(decoded[0].content.first?.text == "first")
        #expect(decoded[1].kind == "emsg")
        #expect(decoded[1].content.first?.hlID == 9)
    }
}
