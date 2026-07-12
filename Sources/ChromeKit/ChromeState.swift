// ChromeState: the single consumer of chrome-relevant redraw events.
// Headless (no AppKit) so all event-application logic is unit-testable.
import Foundation
import NvimKit

/// Applies `RedrawBatch`es, keeping models for the externalized UI surfaces:
/// cmdline, popupmenu, messages, tabline. All other events are ignored.
///
/// Observation: `onChange` fires at most once per `apply(_:)` call, and only
/// if that batch actually mutated something (coalesced, not per-event).
@MainActor
public final class ChromeState {
    // MARK: Observed state

    /// The visible (topmost-level) cmdline, or nil when hidden.
    public private(set) var cmdline: CmdlineModel?
    /// The completion popup, or nil when hidden.
    public private(set) var popupmenu: PopupMenuModel?
    /// Messages since the last `msg_clear`, in display order.
    public private(set) var messages: [MessageModel] = []
    /// The most recent confirm-kind message, if unanswered. The app routes
    /// this to an NSAlert; toasts never show it. Call `clearPendingConfirm()`
    /// once the alert is presented.
    public private(set) var pendingConfirm: MessageModel?
    /// `msg_showmode` content (e.g. "-- INSERT --"); empty when cleared.
    public private(set) var showmode: [Chunk] = []
    /// `msg_showcmd` content (pending operator/count).
    public private(set) var showcmd: [Chunk] = []
    /// `msg_ruler` content (line/col when 'ruler' is set).
    public private(set) var ruler: [Chunk] = []
    /// `msg_history_show` entries retained from Neovim's redraw stream.
    public private(set) var history: [MessageModel] = []
    /// Current ext-tabline model. The shipped native strip is instead driven
    /// by the runtime's buffer-oriented `superlemon.buffers` notification.
    public private(set) var tabline = TablineModel()

    /// Invoked once after any `apply(_:)` that mutated state.
    public var onChange: (() -> Void)?

    // MARK: Internals

    /// Nested cmdlines keyed by level (`q:` opens level 1, typing `:` inside
    /// it shows level 2, ...). The visible cmdline is the highest level.
    private var cmdlineLevels: [Int: CmdlineModel] = [:]
    /// Block-mode lines (`cmdline_block_*`); global, not per-level.
    private var blockLines: [[Chunk]] = []

    public init() {}

    public func clearPendingConfirm() {
        pendingConfirm = nil
    }

    // MARK: Event application

    public func apply(_ batch: RedrawBatch) {
        var mutated = false

        for event in batch.events {
            switch event {
            // -- cmdline ----------------------------------------------------
            case let .cmdlineShow(content, pos, firstc, prompt, indent, level):
                cmdlineLevels[level] = CmdlineModel(
                    content: content.map { Chunk($0) },
                    pos: pos,
                    firstc: firstc,
                    prompt: prompt,
                    indent: indent,
                    level: level,
                    specialChar: nil  // a new show clears any pending special char
                )
                refreshCmdline()
                mutated = true

            case let .cmdlinePos(pos, level):
                if var model = cmdlineLevels[level], model.pos != pos {
                    model.pos = pos
                    cmdlineLevels[level] = model
                    refreshCmdline()
                    mutated = true
                }

            case let .cmdlineSpecialChar(c, shift, level):
                if var model = cmdlineLevels[level] {
                    model.specialChar = SpecialChar(c: c, shift: shift)
                    cmdlineLevels[level] = model
                    refreshCmdline()
                    mutated = true
                }

            case let .cmdlineHide(level):
                if cmdlineLevels.removeValue(forKey: level) != nil {
                    refreshCmdline()
                    mutated = true
                }

            case let .cmdlineBlockShow(lines):
                blockLines = lines.map { $0.map { Chunk($0) } }
                refreshCmdline()
                mutated = true

            case let .cmdlineBlockAppend(line):
                blockLines.append(line.map { Chunk($0) })
                refreshCmdline()
                mutated = true

            case .cmdlineBlockHide:
                if !blockLines.isEmpty {
                    blockLines = []
                    refreshCmdline()
                    mutated = true
                }

            // -- popupmenu --------------------------------------------------
            case let .popupmenuShow(items, selected, row, col, grid):
                popupmenu = PopupMenuModel(
                    items: items,
                    selected: Self.clampSelection(selected, itemCount: items.count),
                    row: row, col: col, grid: grid
                )
                mutated = true

            case let .popupmenuSelect(selected):
                if var menu = popupmenu {
                    let clamped = Self.clampSelection(selected, itemCount: menu.items.count)
                    if clamped != menu.selected {
                        menu.selected = clamped
                        popupmenu = menu
                        mutated = true
                    }
                }

            case .popupmenuHide:
                if popupmenu != nil {
                    popupmenu = nil
                    mutated = true
                }

            // -- messages ---------------------------------------------------
            case let .msgShow(kind, content, replaceLast):
                let isConfirm = kind == "confirm" || kind == "confirm_sub"
                let model = MessageModel(
                    kind: kind,
                    content: content.map { Chunk($0) },
                    needsPrompt: isConfirm
                )
                if replaceLast, !messages.isEmpty {
                    messages[messages.count - 1] = model
                } else {
                    messages.append(model)
                }
                if isConfirm { pendingConfirm = model }
                mutated = true

            case .msgClear:
                if !messages.isEmpty || pendingConfirm != nil {
                    messages = []
                    pendingConfirm = nil
                    mutated = true
                }

            case let .msgShowmode(content):
                let chunks = content.map { Chunk($0) }
                if chunks != showmode {
                    showmode = chunks
                    mutated = true
                }

            case let .msgShowcmd(content):
                let chunks = content.map { Chunk($0) }
                if chunks != showcmd {
                    showcmd = chunks
                    mutated = true
                }

            case let .msgRuler(content):
                let chunks = content.map { Chunk($0) }
                if chunks != ruler {
                    ruler = chunks
                    mutated = true
                }

            case let .msgHistoryShow(entries):
                history = entries.map { entry in
                    MessageModel(kind: entry.kind, content: entry.content.map { Chunk($0) })
                }
                mutated = true

            // -- tabline ----------------------------------------------------
            case let .tablineUpdate(currentTab, tabs):
                let model = TablineModel(currentTab: currentTab, tabs: tabs.map { $0.name })
                if model != tabline {
                    tabline = model
                    mutated = true
                }

            // -- everything else is not chrome ------------------------------
            default:
                break
            }
        }

        if mutated { onChange?() }
    }

    /// Visible cmdline = highest remaining level, with block lines stamped on.
    private func refreshCmdline() {
        if let top = cmdlineLevels.keys.max(), var model = cmdlineLevels[top] {
            model.blockLines = blockLines
            cmdline = model
        } else {
            cmdline = nil
        }
    }

    /// Clamp a popupmenu selection into `-1 ..< itemCount`.
    private static func clampSelection(_ selected: Int, itemCount: Int) -> Int {
        if selected < 0 || itemCount == 0 { return -1 }
        return min(selected, itemCount - 1)
    }
}
