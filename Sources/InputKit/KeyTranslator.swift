// KeyTranslator — pure KeyInput -> nvim key-notation translation
// (DESIGN.md §7.1).
//
// Notation conventions implemented here (per `:h key-notation` and nvim's
// keycodes.c), noted because the docs leave GUI authors some latitude:
//
// - **Modifier order** inside `<...>` follows nvim's own `mod_mask_table`
//   emission order: `M-` (Meta/Option), `C-` (Ctrl), `S-` (Shift),
//   `D-` (Cmd). Nvim *parses* any order, but we emit canonically:
//   `<C-S-Tab>`, `<M-D-s>`, `<M-C-S-D-F5>`.
//
// - **Shift on letters**: for ASCII letters, nvim treats `<C-a>` and `<C-A>`
//   as the same key; the distinguishable form for Ctrl+Shift+A is `<C-S-a>`
//   (S- modifier + lowercase base). We follow that: a chorded cased letter
//   with Shift held becomes `S-` + lowercased letter. For non-letter keys
//   Shift is already absorbed into `charactersIgnoringModifiers`
//   (Shift+1 → "!"), so Ctrl+Shift+1 is `<C-!>` with no `S-`.
//
// - **Shift alone on printables** never translates: "A" is just text and
//   belongs to the IME path.
//
// - **Special keys** always name Shift explicitly (`<S-Tab>`), since there is
//   no character for it to be absorbed into. Likewise a pressed Option always
//   contributes `M-` on special keys regardless of the Option policy — the
//   IME has no use for Option+Arrow, and `<M-Left>` is what users can map.
//
// - **Option policy interaction with chords**: the per-side policy decides
//   routing only when Option is the *strongest* modifier. Once Ctrl or Cmd is
//   in the chord the event can never go to the IME, so Option contributes
//   `M-` even on a side configured as `.option` (Cmd+Opt+S → `<M-D-s>`).
//
// - **Chord-internal names**: characters that collide with notation syntax
//   are emitted by their nvim key names inside chords: `<` → `lt`,
//   `|` → `Bar`, `\` → `Bslash`, space → `Space` (all present in nvim's
//   key_names_table, so `<C-lt>`, `<C-Bar>`, `<C-Space>` parse correctly).
//
// - **Literal text** sent through `nvim_input` needs only `<` escaped, as
//   `<lt>` (`escapeForInput`).

/// Translates `KeyInput` values into nvim key notation. Stateless and pure;
/// see `KeyTranslation` for the three possible routings.
public struct KeyTranslator: Sendable {
    public init() {}

    /// Translate one key-down event.
    ///
    /// - Parameters:
    ///   - input: the pure key event (see `KeyInput`).
    ///   - policy: per-side Option behavior; defaults to left = Meta,
    ///     right = Option (DESIGN.md §7.1).
    public func translate(
        _ input: KeyInput,
        policy: OptionPolicy = .default
    ) -> KeyTranslation {
        // Modifier keys pressed on their own do nothing, and keypad Clear
        // has no nvim name and no character payload.
        if VirtualKey.modifierKeyCodes.contains(input.keyCode)
            || input.keyCode == VirtualKey.keypadClear {
            return .ignored
        }

        let mods = input.modifiers
        let ctrl = mods.contains(.control)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)

        // Named special keys translate unconditionally, with every held
        // modifier spelled out (Option is always M- here; see header note).
        if let name = VirtualKey.specialKeyNames[input.keyCode] {
            let prefix = Self.modifierPrefix(
                meta: option, ctrl: ctrl, shift: shift, cmd: cmd
            )
            return .input("<\(prefix)\(name)>")
        }

        // Printable path. Without Ctrl/Cmd — and with Option either absent or
        // acting as macOS Option — the IME owns the event (plain text, é/∂,
        // dead keys, marked text).
        let optionIsMeta = policy.optionActsAsMeta(for: mods)
        guard ctrl || cmd || optionIsMeta else {
            return .passToIME
        }

        // Chord: build <mods-base> from the Shift-only interpretation of the
        // key (Ctrl and Option stripped, Shift applied).
        var base = input.charactersIgnoringModifiers ?? input.characters ?? ""
        guard !base.isEmpty else {
            // A chorded dead key or character-less event: nothing to send.
            return .ignored
        }

        var includeShift = false
        if shift, base.lowercased() != base.uppercased() || base == " " {
            // Cased letter with Shift held: nvim can't see case through a
            // chord (<C-A> == <C-a>), so encode Shift explicitly: <C-S-a>.
            // Space gets the same treatment — Shift can't be absorbed into
            // it, and <C-S-Space> is a distinct mappable key.
            includeShift = true
            base = base.lowercased()
        } else if !shift {
            // Defensive: Caps Lock may uppercase the base character; chords
            // use the lowercase form when Shift is not held.
            base = base.lowercased()
        }
        // else: Shift held but already absorbed into a symbol ("!") — keep it.

        base = Self.chordName(for: base)
        let prefix = Self.modifierPrefix(
            meta: option, ctrl: ctrl, shift: includeShift, cmd: cmd
        )
        return .input("<\(prefix)\(base)>")
    }

    /// Escape literal text for `nvim_input` (the `NSTextInputClient`
    /// `insertText` commit path): `<` becomes `<lt>`, everything else passes
    /// through untouched.
    public static func escapeForInput(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "<lt>")
    }

    // MARK: - Internals

    /// Canonical nvim modifier prefix: M-, C-, S-, D- in that order.
    private static func modifierPrefix(
        meta: Bool, ctrl: Bool, shift: Bool, cmd: Bool
    ) -> String {
        var prefix = ""
        if meta { prefix += "M-" }
        if ctrl { prefix += "C-" }
        if shift { prefix += "S-" }
        if cmd { prefix += "D-" }
        return prefix
    }

    /// Nvim key names for characters that can't appear raw inside `<...>`.
    private static func chordName(for base: String) -> String {
        switch base {
        case "<": return "lt"
        case "|": return "Bar"
        case "\\": return "Bslash"
        case " ": return "Space"
        default: return base
        }
    }
}
