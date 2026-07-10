// ChromeKit models: plain value types describing nvim's externalized UI state.
// Produced by ChromeState from RedrawBatch events, consumed by the view
// controllers (and headless tests). No AppKit here.
import Foundation
import NvimKit

/// ChromeKit's owned copy of a styled content chunk. NvimKit's `StyledChunk`
/// is a tuple; this struct gives us Equatable arrays and stable API.
public struct Chunk: Sendable, Equatable {
    public var hlID: Int
    public var text: String

    public init(hlID: Int, text: String) {
        self.hlID = hlID
        self.text = text
    }

    public init(_ chunk: StyledChunk) {
        self.hlID = chunk.hlID
        self.text = chunk.text
    }
}

extension [Chunk] {
    /// Concatenated plain text of all chunks.
    public var joinedText: String { map(\.text).joined() }
}

/// A pending special character from `cmdline_special_char` (e.g. the `^`
/// placeholder shown after `<C-v>`). Cleared by the next `cmdline_show`.
public struct SpecialChar: Sendable, Equatable {
    public var c: String
    public var shift: Bool

    public init(c: String, shift: Bool) {
        self.c = c
        self.shift = shift
    }
}

/// The visible command line (topmost level when cmdlines nest, e.g. `q:`
/// then `:`). `nil` on ChromeState means hidden.
public struct CmdlineModel: Sendable, Equatable {
    /// Styled content of the line. `pos` indexes into the *bytes* (UTF-8) of
    /// the concatenated chunk text, per the ext_cmdline protocol.
    public var content: [Chunk]
    public var pos: Int
    /// Leading symbol: ":", "/", "?", "=" — empty when `prompt` is used.
    public var firstc: String
    /// Prompt text for input() style prompts; empty otherwise.
    public var prompt: String
    /// Number of spaces to indent the content by.
    public var indent: Int
    /// Nesting level (1-based). Higher levels stack above lower ones.
    public var level: Int
    /// Pending `<C-v>` special-char placeholder; rendered inverted at `pos`.
    public var specialChar: SpecialChar?
    /// Lines of the current command block (`cmdline_block_*`), shown above
    /// the active line. Empty outside block mode.
    public var blockLines: [[Chunk]]

    public var text: String { content.joinedText }

    public init(
        content: [Chunk] = [],
        pos: Int = 0,
        firstc: String = "",
        prompt: String = "",
        indent: Int = 0,
        level: Int = 1,
        specialChar: SpecialChar? = nil,
        blockLines: [[Chunk]] = []
    ) {
        self.content = content
        self.pos = pos
        self.firstc = firstc
        self.prompt = prompt
        self.indent = indent
        self.level = level
        self.specialChar = specialChar
        self.blockLines = blockLines
    }
}

/// The completion popup. `nil` on ChromeState means hidden.
public struct PopupMenuModel: Sendable, Equatable {
    public var items: [PopupMenuItem]
    /// Selected index; -1 means no selection.
    public var selected: Int
    /// Anchor cell. `grid == -1` anchors to the cmdline (wildmenu).
    public var row: Int
    public var col: Int
    public var grid: Int

    public init(items: [PopupMenuItem], selected: Int = -1, row: Int = 0, col: Int = 0, grid: Int = 0) {
        self.items = items
        self.selected = selected
        self.row = row
        self.col = col
        self.grid = grid
    }
}

/// One `msg_show` message.
public struct MessageModel: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// nvim message kind: "", "echo", "echomsg", "emsg", "echoerr",
    /// "lua_error", "rpc_error", "wmsg", "confirm", "confirm_sub", ...
    public var kind: String
    public var content: [Chunk]
    /// True for confirm-kind messages: routed to NSAlert by the app,
    /// never toasted.
    public var needsPrompt: Bool

    public var text: String { content.joinedText }

    /// Error-kind messages are tinted red and never auto-dismiss.
    public var isError: Bool {
        ["emsg", "echoerr", "lua_error", "rpc_error"].contains(kind)
    }

    public init(id: UUID = UUID(), kind: String, content: [Chunk], needsPrompt: Bool = false) {
        self.id = id
        self.kind = kind
        self.content = content
        self.needsPrompt = needsPrompt
    }
}

/// Decoded `tabline_update`: current tabpage index + labels.
/// Feeds a buffer/workspace switcher later (NORTHSTAR delta 4); no view
/// in this wave.
public struct TablineModel: Sendable, Equatable {
    /// Index into `tabs` of the current tabpage.
    public var currentTab: Int
    public var tabs: [String]

    public init(currentTab: Int = 0, tabs: [String] = []) {
        self.currentTab = currentTab
        self.tabs = tabs
    }
}
