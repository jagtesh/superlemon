// macOS virtual keycodes (Carbon HIToolbox `kVK_*` values), hardcoded so
// InputKit needs no Carbon import. Values are from
// <HIToolbox/Events.h> and are stable across all Mac hardware.

/// Named constants for the macOS virtual keycodes InputKit cares about.
public enum VirtualKey {
    // MARK: Editing / whitespace
    public static let returnKey: UInt16     = 0x24  // kVK_Return
    public static let tab: UInt16           = 0x30  // kVK_Tab
    public static let space: UInt16         = 0x31  // kVK_Space
    public static let delete: UInt16        = 0x33  // kVK_Delete (backspace)
    public static let escape: UInt16        = 0x35  // kVK_Escape
    public static let forwardDelete: UInt16 = 0x75  // kVK_ForwardDelete

    // MARK: Modifiers (produce no translation of their own)
    public static let rightCommand: UInt16  = 0x36  // kVK_RightCommand
    public static let command: UInt16       = 0x37  // kVK_Command
    public static let shift: UInt16         = 0x38  // kVK_Shift
    public static let capsLock: UInt16      = 0x39  // kVK_CapsLock
    public static let option: UInt16        = 0x3A  // kVK_Option
    public static let control: UInt16       = 0x3B  // kVK_Control
    public static let rightShift: UInt16    = 0x3C  // kVK_RightShift
    public static let rightOption: UInt16   = 0x3D  // kVK_RightOption
    public static let rightControl: UInt16  = 0x3E  // kVK_RightControl
    public static let functionKey: UInt16   = 0x3F  // kVK_Function (fn/globe)

    // MARK: Navigation
    public static let home: UInt16     = 0x73  // kVK_Home
    public static let pageUp: UInt16   = 0x74  // kVK_PageUp
    public static let end: UInt16      = 0x77  // kVK_End
    public static let pageDown: UInt16 = 0x79  // kVK_PageDown
    public static let leftArrow: UInt16  = 0x7B  // kVK_LeftArrow
    public static let rightArrow: UInt16 = 0x7C  // kVK_RightArrow
    public static let downArrow: UInt16  = 0x7D  // kVK_DownArrow
    public static let upArrow: UInt16    = 0x7E  // kVK_UpArrow
    /// kVK_Help — the Insert-position key on extended keyboards.
    public static let help: UInt16 = 0x72

    // MARK: Function keys
    public static let f1: UInt16  = 0x7A
    public static let f2: UInt16  = 0x78
    public static let f3: UInt16  = 0x63
    public static let f4: UInt16  = 0x76
    public static let f5: UInt16  = 0x60
    public static let f6: UInt16  = 0x61
    public static let f7: UInt16  = 0x62
    public static let f8: UInt16  = 0x64
    public static let f9: UInt16  = 0x65
    public static let f10: UInt16 = 0x6D
    public static let f11: UInt16 = 0x67
    public static let f12: UInt16 = 0x6F
    public static let f13: UInt16 = 0x69
    public static let f14: UInt16 = 0x6B
    public static let f15: UInt16 = 0x71
    public static let f16: UInt16 = 0x6A
    public static let f17: UInt16 = 0x40
    public static let f18: UInt16 = 0x4F
    public static let f19: UInt16 = 0x50
    public static let f20: UInt16 = 0x5A

    // MARK: Keypad (ANSI block)
    public static let keypadDecimal: UInt16  = 0x41  // kVK_ANSI_KeypadDecimal
    public static let keypadMultiply: UInt16 = 0x43  // kVK_ANSI_KeypadMultiply
    public static let keypadPlus: UInt16     = 0x45  // kVK_ANSI_KeypadPlus
    public static let keypadClear: UInt16    = 0x47  // kVK_ANSI_KeypadClear
    public static let keypadDivide: UInt16   = 0x4B  // kVK_ANSI_KeypadDivide
    public static let keypadEnter: UInt16    = 0x4C  // kVK_ANSI_KeypadEnter
    public static let keypadMinus: UInt16    = 0x4E  // kVK_ANSI_KeypadMinus
    public static let keypadEquals: UInt16   = 0x51  // kVK_ANSI_KeypadEquals
    public static let keypad0: UInt16 = 0x52
    public static let keypad1: UInt16 = 0x53
    public static let keypad2: UInt16 = 0x54
    public static let keypad3: UInt16 = 0x55
    public static let keypad4: UInt16 = 0x56
    public static let keypad5: UInt16 = 0x57
    public static let keypad6: UInt16 = 0x58
    public static let keypad7: UInt16 = 0x59
    public static let keypad8: UInt16 = 0x5B
    public static let keypad9: UInt16 = 0x5C
    public static let keypadComma: UInt16 = 0x5F  // kVK_JIS_KeypadComma

    /// Keycodes that are modifier keys themselves — their keyDown (and any
    /// flagsChanged) events translate to `.ignored`.
    public static let modifierKeyCodes: Set<UInt16> = [
        rightCommand, command, shift, capsLock, option,
        control, rightShift, rightOption, rightControl, functionKey,
    ]

    /// Nvim special-key names (`:h key-notation`) keyed by virtual keycode.
    ///
    /// Notation decisions:
    /// - Backspace (kVK_Delete) is `<BS>`, forward delete is `<Del>` — matching
    ///   nvim's names, not Apple's.
    /// - kVK_Help is mapped to `<Insert>`: it occupies the Insert position on
    ///   extended keyboards and every terminal/GUI treats it as Insert.
    /// - Keypad keys use nvim's `<k...>` family (`<k0>`–`<k9>`, `<kPlus>`,
    ///   `<kEnter>`, `<kPoint>`, `<kComma>`, `<kEqual>`, …) so users can map
    ///   them distinctly from the top-row equivalents.
    /// - kVK_ANSI_KeypadClear has no nvim name and is deliberately absent
    ///   (it translates to `.ignored`).
    /// - Space is *not* in this table: bare Space is printable text (IME
    ///   path); chorded Space is named in the printable-chord path
    ///   (`<C-Space>` etc.).
    public static let specialKeyNames: [UInt16: String] = [
        escape: "Esc",
        returnKey: "CR",
        delete: "BS",
        forwardDelete: "Del",
        tab: "Tab",
        upArrow: "Up",
        downArrow: "Down",
        leftArrow: "Left",
        rightArrow: "Right",
        home: "Home",
        end: "End",
        pageUp: "PageUp",
        pageDown: "PageDown",
        help: "Insert",
        f1: "F1", f2: "F2", f3: "F3", f4: "F4", f5: "F5",
        f6: "F6", f7: "F7", f8: "F8", f9: "F9", f10: "F10",
        f11: "F11", f12: "F12", f13: "F13", f14: "F14", f15: "F15",
        f16: "F16", f17: "F17", f18: "F18", f19: "F19", f20: "F20",
        keypad0: "k0", keypad1: "k1", keypad2: "k2", keypad3: "k3",
        keypad4: "k4", keypad5: "k5", keypad6: "k6", keypad7: "k7",
        keypad8: "k8", keypad9: "k9",
        keypadDecimal: "kPoint",
        keypadComma: "kComma",
        keypadPlus: "kPlus",
        keypadMinus: "kMinus",
        keypadMultiply: "kMultiply",
        keypadDivide: "kDivide",
        keypadEnter: "kEnter",
        keypadEquals: "kEqual",
    ]
}
