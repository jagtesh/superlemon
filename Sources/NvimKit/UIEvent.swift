/// Typed redraw events, decoded from nvim's `redraw` notification batches.
/// See DESIGN.md §4 and `:h ui-events` (linegrid + multigrid + externalized UI).
///
/// This enum is the contract between NvimKit (producer) and GridKit/ChromeKit
/// (consumers). Unknown wire events are skipped by the decoder, never surfaced.

public struct RGBColor: Sendable, Equatable, Hashable {
    public var rgb: UInt32  // 0xRRGGBB
    public init(rgb: UInt32) { self.rgb = rgb }
}

/// Highlight attributes from `hl_attr_define` (rgb_attr form).
public struct HlAttrs: Sendable, Equatable {
    public var foreground: RGBColor?
    public var background: RGBColor?
    public var special: RGBColor?
    public var reverse = false
    public var bold = false
    public var italic = false
    public var strikethrough = false
    public var underline = false
    public var undercurl = false
    public var underdouble = false
    public var underdotted = false
    public var underdashed = false
    public var blend: Int = 0
    public init() {}
}

/// One entry of a `mode_info_set` payload.
public struct ModeInfo: Sendable, Equatable {
    public enum CursorShape: String, Sendable { case block, horizontal, vertical }
    public var name: String = ""
    public var shortName: String = ""
    public var cursorShape: CursorShape = .block
    public var cellPercentage: Int = 100
    public var blinkWait: Int = 0
    public var blinkOn: Int = 0
    public var blinkOff: Int = 0
    public var attrID: Int = 0
    public init() {}
}

/// A run of identical-highlight cells within a `grid_line` event.
/// `text` is one grapheme cluster; `repeatCount` expands it horizontally.
public struct CellRun: Sendable, Equatable {
    public var text: String
    public var hlID: Int
    public var repeatCount: Int
    public init(text: String, hlID: Int, repeatCount: Int = 1) {
        self.text = text
        self.hlID = hlID
        self.repeatCount = repeatCount
    }
}

/// Item of a `popupmenu_show` payload: [word, kind, menu, info].
public struct PopupMenuItem: Sendable, Equatable {
    public var word: String
    public var kind: String
    public var menu: String
    public var info: String
    public init(word: String, kind: String = "", menu: String = "", info: String = "") {
        self.word = word
        self.kind = kind
        self.menu = menu
        self.info = info
    }
}

/// A chunk of styled message/cmdline content: (hlID, text).
public typealias StyledChunk = (hlID: Int, text: String)

public enum UIEvent: Sendable {
    // -- global ------------------------------------------------------------
    case setTitle(String)
    case setIcon(String)
    case modeInfoSet(cursorStyleEnabled: Bool, modes: [ModeInfo])
    case modeChange(mode: String, modeIndex: Int)
    case optionSet(name: String, value: Value)
    case busyStart
    case busyStop
    case mouseOn
    case mouseOff
    case bell
    case visualBell
    case suspend
    case updateMenu
    case chdir(String)
    case flush

    // -- highlight ---------------------------------------------------------
    case defaultColorsSet(fg: RGBColor, bg: RGBColor, special: RGBColor)
    case hlAttrDefine(id: Int, attrs: HlAttrs)
    case hlGroupSet(name: String, id: Int)

    // -- linegrid ----------------------------------------------------------
    case gridResize(grid: Int, width: Int, height: Int)
    case gridClear(grid: Int)
    case gridDestroy(grid: Int)
    case gridCursorGoto(grid: Int, row: Int, col: Int)
    case gridLine(grid: Int, row: Int, colStart: Int, cells: [CellRun], wrap: Bool)
    /// Positive `rows` scrolls content up (region moves toward the top).
    case gridScroll(grid: Int, top: Int, bottom: Int, left: Int, right: Int, rows: Int, cols: Int)

    // -- multigrid ---------------------------------------------------------
    case winPos(grid: Int, win: Int, startRow: Int, startCol: Int, width: Int, height: Int)
    case winFloatPos(
        grid: Int, win: Int, anchor: String, anchorGrid: Int,
        anchorRow: Double, anchorCol: Double, focusable: Bool, zIndex: Int)
    case winExternalPos(grid: Int, win: Int)
    case winHide(grid: Int)
    case winClose(grid: Int)
    case msgSetPos(grid: Int, row: Int, scrolled: Bool, sepChar: String)
    case winViewport(
        grid: Int, win: Int, topline: Int, botline: Int,
        curline: Int, curcol: Int, lineCount: Int, scrollDelta: Int)

    // -- ext_cmdline ---------------------------------------------------------
    case cmdlineShow(content: [StyledChunk], pos: Int, firstc: String, prompt: String, indent: Int, level: Int)
    case cmdlinePos(pos: Int, level: Int)
    case cmdlineSpecialChar(c: String, shift: Bool, level: Int)
    case cmdlineHide(level: Int)
    case cmdlineBlockShow(lines: [[StyledChunk]])
    case cmdlineBlockAppend(line: [StyledChunk])
    case cmdlineBlockHide

    // -- ext_popupmenu -------------------------------------------------------
    case popupmenuShow(items: [PopupMenuItem], selected: Int, row: Int, col: Int, grid: Int)
    case popupmenuSelect(selected: Int)
    case popupmenuHide

    // -- ext_tabline ---------------------------------------------------------
    /// Opaque tab handles + labels; curtab is an index into `tabs`.
    case tablineUpdate(currentTab: Int, tabs: [(handle: Value, name: String)])

    // -- ext_messages --------------------------------------------------------
    case msgShow(kind: String, content: [StyledChunk], replaceLast: Bool)
    case msgClear
    case msgShowmode(content: [StyledChunk])
    case msgShowcmd(content: [StyledChunk])
    case msgRuler(content: [StyledChunk])
    case msgHistoryShow(entries: [(kind: String, content: [StyledChunk])])
}

/// One decoded `redraw` notification: events in wire order.
/// A batch ending in `.flush` is a complete, presentable frame.
public struct RedrawBatch: Sendable {
    public var events: [UIEvent]
    public init(events: [UIEvent]) { self.events = events }
}
