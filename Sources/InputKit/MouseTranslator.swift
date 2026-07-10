// MouseTranslator — pure mapping from mouse events to `nvim_input_mouse`
// arguments (DESIGN.md §7.4, `:h nvim_input_mouse`).

/// A physical mouse button, named as nvim expects them.
public enum MouseButton: String, Sendable, Hashable {
    case left, right, middle
}

/// A button gesture phase, named as nvim expects them.
public enum MouseAction: String, Sendable, Hashable {
    case press, drag, release
}

/// A wheel step direction (`button: "wheel"` in `nvim_input_mouse`).
public enum WheelDirection: String, Sendable, Hashable {
    case up, down, left, right
}

/// The exact argument tuple for `nvim_input_mouse(button, action, modifier,
/// grid, row, col)`.
public struct MouseInputArguments: Sendable, Hashable {
    public var button: String
    public var action: String
    public var modifier: String
    public var grid: Int
    public var row: Int
    public var col: Int

    public init(
        button: String, action: String, modifier: String,
        grid: Int, row: Int, col: Int
    ) {
        self.button = button
        self.action = action
        self.modifier = modifier
        self.grid = grid
        self.row = row
        self.col = col
    }
}

/// Stateless translator producing `nvim_input_mouse` argument tuples.
///
/// Modifier strings use the single-character specifiers from
/// `:h nvim_input_mouse` ("the same specifiers as for a key press, the `-`
/// separator is optional"): we emit lowercase, in the same canonical order as
/// key chords — `m` (Option), `c` (Ctrl), `s` (Shift), `d` (Cmd) — followed by
/// the multi-click count (`2`/`3`/`4`, mirroring `<2-LeftMouse>` notation).
public struct MouseTranslator: Sendable {
    public init() {}

    /// Translate a button event.
    ///
    /// - Parameters:
    ///   - clickCount: NSEvent's `clickCount`. Counts of 2–4 are encoded into
    ///     the modifier string on `press` events (nvim's double/triple/
    ///     quadruple-click notation); higher counts clamp to 4, and drag/
    ///     release events never carry a count (matching `:h key-notation`,
    ///     where only the click itself is `<2-LeftMouse>`).
    ///   - row, col: zero-based cell coordinates on `grid` (multigrid-aware;
    ///     passed through untouched).
    public func translate(
        button: MouseButton,
        action: MouseAction,
        modifiers: Modifiers,
        grid: Int,
        row: Int,
        col: Int,
        clickCount: Int = 1
    ) -> MouseInputArguments {
        let count = action == .press ? clickCount : 1
        return MouseInputArguments(
            button: button.rawValue,
            action: action.rawValue,
            modifier: Self.modifierString(modifiers, clickCount: count),
            grid: grid,
            row: row,
            col: col
        )
    }

    /// Translate one wheel step (as emitted by `ScrollAccumulator`).
    public func translateWheel(
        direction: WheelDirection,
        modifiers: Modifiers,
        grid: Int,
        row: Int,
        col: Int
    ) -> MouseInputArguments {
        MouseInputArguments(
            button: "wheel",
            action: direction.rawValue,
            modifier: Self.modifierString(modifiers, clickCount: 1),
            grid: grid,
            row: row,
            col: col
        )
    }

    // MARK: - Internals

    private static func modifierString(
        _ modifiers: Modifiers, clickCount: Int
    ) -> String {
        var result = ""
        if modifiers.contains(.option) { result += "m" }
        if modifiers.contains(.control) { result += "c" }
        if modifiers.contains(.shift) { result += "s" }
        if modifiers.contains(.command) { result += "d" }
        if clickCount >= 2 {
            result += String(min(clickCount, 4))
        }
        return result
    }
}
