import os

/// Decodes nvim `redraw` notification payloads into typed `UIEvent`s.
///
/// The wire shape (see `:h ui-events`) is an array of entries, each
/// `[event_name, args1, args2, ...]` where every argsN array is one
/// invocation of that event. Unknown event names and malformed invocations
/// are logged and skipped — never surfaced (forward compatibility).
public enum RedrawDecoder {
    private static let logger = Logger(subsystem: "dev.superlemon.NvimKit", category: "redraw")

    public static func decode(_ params: [Value]) -> RedrawBatch {
        var events: [UIEvent] = []
        events.reserveCapacity(params.count)
        for entry in params {
            guard let parts = entry.arrayValue, let name = parts.first?.stringValue else {
                logger.debug("skipping malformed redraw entry")
                continue
            }
            guard let decode = table[name] else {
                logger.debug("skipping unknown redraw event: \(name, privacy: .public)")
                continue
            }
            for invocation in parts.dropFirst() {
                guard let args = invocation.arrayValue, let event = decode(args) else {
                    logger.debug("skipping malformed \(name, privacy: .public) invocation")
                    continue
                }
                events.append(event)
            }
        }
        return RedrawBatch(events: events)
    }

    // MARK: - Event table

    private typealias EventDecoder = @Sendable ([Value]) -> UIEvent?

    private static let table: [String: EventDecoder] = [
        // -- global ----------------------------------------------------------
        "set_title": { args in args.first?.stringValue.map { .setTitle($0) } },
        "set_icon": { args in args.first?.stringValue.map { .setIcon($0) } },
        "mode_info_set": { args in
            guard args.count >= 2, let enabled = args[0].boolValue,
                let list = args[1].arrayValue
            else { return nil }
            return .modeInfoSet(cursorStyleEnabled: enabled, modes: list.compactMap(modeInfo))
        },
        "mode_change": { args in
            guard args.count >= 2, let mode = args[0].stringValue, let idx = args[1].intValue
            else { return nil }
            return .modeChange(mode: mode, modeIndex: idx)
        },
        "option_set": { args in
            guard args.count >= 2, let name = args[0].stringValue else { return nil }
            return .optionSet(name: name, value: args[1])
        },
        "busy_start": { _ in .busyStart },
        "busy_stop": { _ in .busyStop },
        "mouse_on": { _ in .mouseOn },
        "mouse_off": { _ in .mouseOff },
        "bell": { _ in .bell },
        "visual_bell": { _ in .visualBell },
        "suspend": { _ in .suspend },
        "update_menu": { _ in .updateMenu },
        "chdir": { args in args.first?.stringValue.map { .chdir($0) } },
        "flush": { _ in .flush },

        // -- highlight ---------------------------------------------------------
        "default_colors_set": { args in
            guard args.count >= 3 else { return nil }
            return .defaultColorsSet(
                fg: rgbColor(args[0]) ?? RGBColor(rgb: 0xFFFFFF),
                bg: rgbColor(args[1]) ?? RGBColor(rgb: 0x000000),
                special: rgbColor(args[2]) ?? RGBColor(rgb: 0xFF0000))
        },
        "hl_attr_define": { args in
            // [id, rgb_attr, cterm_attr, info] — only rgb_attr matters to us.
            guard args.count >= 2, let id = args[0].intValue, let rgbAttr = args[1].mapValue
            else { return nil }
            return .hlAttrDefine(id: id, attrs: hlAttrs(rgbAttr))
        },
        "hl_group_set": { args in
            guard args.count >= 2, let name = args[0].stringValue, let id = args[1].intValue
            else { return nil }
            return .hlGroupSet(name: name, id: id)
        },

        // -- linegrid ----------------------------------------------------------
        "grid_resize": { args in
            guard let ints = ints(args, 3) else { return nil }
            return .gridResize(grid: ints[0], width: ints[1], height: ints[2])
        },
        "grid_clear": { args in args.first?.intValue.map { .gridClear(grid: $0) } },
        "grid_destroy": { args in args.first?.intValue.map { .gridDestroy(grid: $0) } },
        "grid_cursor_goto": { args in
            guard let ints = ints(args, 3) else { return nil }
            return .gridCursorGoto(grid: ints[0], row: ints[1], col: ints[2])
        },
        "grid_line": { args in
            // [grid, row, col_start, cells, wrap]; each cell [text(, hl_id, repeat)].
            // hl_id persists across cells within one invocation when omitted.
            guard args.count >= 4,
                let grid = args[0].intValue, let row = args[1].intValue,
                let colStart = args[2].intValue, let cells = args[3].arrayValue
            else { return nil }
            let wrap = args.count >= 5 ? (args[4].boolValue ?? false) : false
            var runs: [CellRun] = []
            runs.reserveCapacity(cells.count)
            var hlID = 0
            for cell in cells {
                guard let c = cell.arrayValue, let text = c.first?.stringValue else { return nil }
                if c.count >= 2, let hl = c[1].intValue { hlID = hl }
                let repeatCount = c.count >= 3 ? (c[2].intValue ?? 1) : 1
                runs.append(CellRun(text: text, hlID: hlID, repeatCount: repeatCount))
            }
            return .gridLine(grid: grid, row: row, colStart: colStart, cells: runs, wrap: wrap)
        },
        "grid_scroll": { args in
            guard let ints = ints(args, 7) else { return nil }
            return .gridScroll(
                grid: ints[0], top: ints[1], bottom: ints[2], left: ints[3],
                right: ints[4], rows: ints[5], cols: ints[6])
        },

        // -- multigrid ---------------------------------------------------------
        "win_pos": { args in
            guard let ints = ints(args, 6) else { return nil }
            return .winPos(
                grid: ints[0], win: ints[1], startRow: ints[2], startCol: ints[3],
                width: ints[4], height: ints[5])
        },
        "win_float_pos": { args in
            // [grid, win, anchor, anchor_grid, anchor_row, anchor_col,
            //  mouse_enabled, zindex, compindex, screen_row, screen_col]
            guard args.count >= 8,
                let grid = handleInt(args[0]), let win = handleInt(args[1]),
                let anchor = args[2].stringValue, let anchorGrid = args[3].intValue,
                let anchorRow = args[4].doubleValue, let anchorCol = args[5].doubleValue,
                let focusable = args[6].boolValue, let zIndex = args[7].intValue
            else { return nil }
            return .winFloatPos(
                grid: grid, win: win, anchor: anchor, anchorGrid: anchorGrid,
                anchorRow: anchorRow, anchorCol: anchorCol, focusable: focusable,
                zIndex: zIndex)
        },
        "win_external_pos": { args in
            guard let ints = ints(args, 2) else { return nil }
            return .winExternalPos(grid: ints[0], win: ints[1])
        },
        "win_hide": { args in args.first?.intValue.map { .winHide(grid: $0) } },
        "win_close": { args in args.first?.intValue.map { .winClose(grid: $0) } },
        "msg_set_pos": { args in
            // [grid, row, scrolled, sep_char, zindex, compindex]
            guard args.count >= 4,
                let grid = args[0].intValue, let row = args[1].intValue,
                let scrolled = args[2].boolValue, let sepChar = args[3].stringValue
            else { return nil }
            return .msgSetPos(grid: grid, row: row, scrolled: scrolled, sepChar: sepChar)
        },
        "win_viewport": { args in
            guard let ints = ints(args, 8) else { return nil }
            return .winViewport(
                grid: ints[0], win: ints[1], topline: ints[2], botline: ints[3],
                curline: ints[4], curcol: ints[5], lineCount: ints[6], scrollDelta: ints[7])
        },
        "win_viewport_margins": { args in
            guard let ints = ints(args, 6) else { return nil }
            return .winViewportMargins(
                grid: ints[0], win: ints[1], top: ints[2], bottom: ints[3],
                left: ints[4], right: ints[5])
        },

        // -- ext_cmdline ---------------------------------------------------------
        "cmdline_show": { args in
            // [content, pos, firstc, prompt, indent, level, hl_id]
            guard args.count >= 6,
                let pos = args[1].intValue, let firstc = args[2].stringValue,
                let prompt = args[3].stringValue, let indent = args[4].intValue,
                let level = args[5].intValue
            else { return nil }
            return .cmdlineShow(
                content: styledChunks(args[0]), pos: pos, firstc: firstc,
                prompt: prompt, indent: indent, level: level)
        },
        "cmdline_pos": { args in
            guard let ints = ints(args, 2) else { return nil }
            return .cmdlinePos(pos: ints[0], level: ints[1])
        },
        "cmdline_special_char": { args in
            guard args.count >= 3, let c = args[0].stringValue,
                let shift = args[1].boolValue, let level = args[2].intValue
            else { return nil }
            return .cmdlineSpecialChar(c: c, shift: shift, level: level)
        },
        "cmdline_hide": { args in args.first?.intValue.map { .cmdlineHide(level: $0) } },
        "cmdline_block_show": { args in
            guard let lines = args.first?.arrayValue else { return nil }
            return .cmdlineBlockShow(lines: lines.map(styledChunks))
        },
        "cmdline_block_append": { args in
            guard let line = args.first else { return nil }
            return .cmdlineBlockAppend(line: styledChunks(line))
        },
        "cmdline_block_hide": { _ in .cmdlineBlockHide },

        // -- ext_popupmenu -------------------------------------------------------
        "popupmenu_show": { args in
            // [items, selected, row, col, grid]; item [word, kind, menu, info]
            guard args.count >= 5, let items = args[0].arrayValue,
                let selected = args[1].intValue, let row = args[2].intValue,
                let col = args[3].intValue, let grid = args[4].intValue
            else { return nil }
            let menuItems = items.compactMap { item -> PopupMenuItem? in
                guard let fields = item.arrayValue, let word = fields.first?.stringValue
                else { return nil }
                return PopupMenuItem(
                    word: word,
                    kind: fields.count > 1 ? fields[1].stringValue ?? "" : "",
                    menu: fields.count > 2 ? fields[2].stringValue ?? "" : "",
                    info: fields.count > 3 ? fields[3].stringValue ?? "" : "")
            }
            return .popupmenuShow(items: menuItems, selected: selected, row: row, col: col, grid: grid)
        },
        "popupmenu_select": { args in
            args.first?.intValue.map { .popupmenuSelect(selected: $0) }
        },
        "popupmenu_hide": { _ in .popupmenuHide },

        // -- ext_tabline ---------------------------------------------------------
        "tabline_update": { args in
            // [curtab, tabs, curbuf, buffers]; curtab is a Tabpage handle and
            // tabs is [{ "tab": Tabpage, "name": String }, ...]. The UIEvent
            // contract wants curtab as an index into `tabs`, so resolve it.
            guard args.count >= 2, let tabList = args[1].arrayValue else { return nil }
            var tabs: [(handle: Value, name: String)] = []
            for tab in tabList {
                guard let fields = tab.mapValue else { continue }
                var handle = Value.nil
                var name = ""
                for (key, value) in fields {
                    switch key.stringValue {
                    case "tab": handle = value
                    case "name": name = value.stringValue ?? ""
                    default: break
                    }
                }
                tabs.append((handle: handle, name: name))
            }
            let current = tabs.firstIndex { $0.handle == args[0] } ?? 0
            return .tablineUpdate(currentTab: current, tabs: tabs)
        },

        // -- ext_messages --------------------------------------------------------
        "msg_show": { args in
            // [kind, content, replace_last, history, append, id, trigger]
            guard args.count >= 3, let kind = args[0].stringValue,
                let replaceLast = args[2].boolValue
            else { return nil }
            return .msgShow(kind: kind, content: styledChunks(args[1]), replaceLast: replaceLast)
        },
        "msg_clear": { _ in .msgClear },
        "msg_showmode": { args in
            guard let content = args.first else { return nil }
            return .msgShowmode(content: styledChunks(content))
        },
        "msg_showcmd": { args in
            guard let content = args.first else { return nil }
            return .msgShowcmd(content: styledChunks(content))
        },
        "msg_ruler": { args in
            guard let content = args.first else { return nil }
            return .msgRuler(content: styledChunks(content))
        },
        "msg_history_show": { args in
            // [entries, prev_cmd]; entry [kind, content, append]
            guard let entryList = args.first?.arrayValue else { return nil }
            let entries = entryList.compactMap { entry -> (kind: String, content: [StyledChunk])? in
                guard let fields = entry.arrayValue, fields.count >= 2,
                    let kind = fields[0].stringValue
                else { return nil }
                return (kind: kind, content: styledChunks(fields[1]))
            }
            return .msgHistoryShow(entries: entries)
        },
    ]

    // MARK: - Field helpers

    /// First `count` args as Ints; window/buffer/tabpage ext handles unwrap.
    private static func ints(_ args: [Value], _ count: Int) -> [Int]? {
        guard args.count >= count else { return nil }
        var result: [Int] = []
        result.reserveCapacity(count)
        for arg in args.prefix(count) {
            guard let value = handleInt(arg) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Int from a plain integer or from an EXT-encoded API handle
    /// (Buffer/Window/Tabpage are ext values wrapping a msgpack integer).
    private static func handleInt(_ value: Value) -> Int? {
        if let int = value.intValue { return int }
        if case .ext(_, let data) = value {
            return (try? MsgpackDecoder.decode(data))?.intValue
        }
        return nil
    }

    private static func rgbColor(_ value: Value) -> RGBColor? {
        guard let int = value.intValue, int >= 0 else { return nil }
        return RGBColor(rgb: UInt32(truncatingIfNeeded: int) & 0xFF_FFFF)
    }

    /// `hl_attr_define` rgb_attrs dict -> HlAttrs. Absent color keys mean
    /// "use default" (nil); boolean keys are only sent when true.
    private static func hlAttrs(_ map: [(Value, Value)]) -> HlAttrs {
        var attrs = HlAttrs()
        for (key, value) in map {
            switch key.stringValue {
            case "foreground": attrs.foreground = rgbColor(value)
            case "background": attrs.background = rgbColor(value)
            case "special": attrs.special = rgbColor(value)
            case "reverse": attrs.reverse = value.boolValue ?? false
            case "bold": attrs.bold = value.boolValue ?? false
            case "italic": attrs.italic = value.boolValue ?? false
            case "strikethrough": attrs.strikethrough = value.boolValue ?? false
            case "underline": attrs.underline = value.boolValue ?? false
            case "undercurl": attrs.undercurl = value.boolValue ?? false
            case "underdouble": attrs.underdouble = value.boolValue ?? false
            case "underdotted": attrs.underdotted = value.boolValue ?? false
            case "underdashed": attrs.underdashed = value.boolValue ?? false
            case "blend": attrs.blend = value.intValue ?? 0
            default: break  // altfont/dim/blink/conceal/overline/url: not in contract
            }
        }
        return attrs
    }

    private static func modeInfo(_ value: Value) -> ModeInfo? {
        guard let map = value.mapValue else { return nil }
        var info = ModeInfo()
        for (key, value) in map {
            switch key.stringValue {
            case "name": info.name = value.stringValue ?? ""
            case "short_name": info.shortName = value.stringValue ?? ""
            case "cursor_shape":
                info.cursorShape =
                    value.stringValue.flatMap(ModeInfo.CursorShape.init(rawValue:)) ?? .block
            case "cell_percentage": info.cellPercentage = value.intValue ?? 100
            case "blinkwait": info.blinkWait = value.intValue ?? 0
            case "blinkon": info.blinkOn = value.intValue ?? 0
            case "blinkoff": info.blinkOff = value.intValue ?? 0
            case "attr_id": info.attrID = value.intValue ?? 0
            default: break
            }
        }
        return info
    }

    /// Content chunk list -> [StyledChunk]. Handles both the classic
    /// `[attr_id, text]` form (msg_*, cmdline in practice) and the
    /// documented `[attrs_dict, text, hl_id]` form (hl_id wins there).
    private static func styledChunks(_ value: Value) -> [StyledChunk] {
        guard let chunks = value.arrayValue else { return [] }
        return chunks.compactMap { chunk -> StyledChunk? in
            guard let fields = chunk.arrayValue, fields.count >= 2,
                let text = fields[1].stringValue
            else { return nil }
            let hlID = fields[0].intValue ?? (fields.count >= 3 ? fields[2].intValue ?? 0 : 0)
            return (hlID: hlID, text: text)
        }
    }
}
