// InputKit — pure input-translation layer (DESIGN.md §7).
//
// InputKit has no dependency on NvimKit or AppKit: the core operates on plain
// value types and produces Strings in nvim key notation (`:h key-notation`).
// A thin adapter in NSEventTranslation.swift bridges NSEvent to these types.

/// Modifier flags carried by a `KeyInput`.
///
/// The raw values mirror `NSEvent.ModifierFlags` exactly, so an NSEvent's
/// `modifierFlags.rawValue` can be passed through unchanged. The low 16 bits
/// are the device-dependent bits (`NX_DEVICE*KEYMASK` from IOKit's
/// `IOLLEvent.h`), which AppKit preserves in the raw value; InputKit uses the
/// left/right Option bits to apply the per-side Option policy.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    // MARK: Device-independent bits (== NSEvent.ModifierFlags)

    public static let capsLock   = Modifiers(rawValue: 1 << 16)
    public static let shift      = Modifiers(rawValue: 1 << 17)
    public static let control    = Modifiers(rawValue: 1 << 18)
    public static let option     = Modifiers(rawValue: 1 << 19)
    public static let command    = Modifiers(rawValue: 1 << 20)
    public static let numericPad = Modifiers(rawValue: 1 << 21)
    public static let help       = Modifiers(rawValue: 1 << 22)
    public static let function   = Modifiers(rawValue: 1 << 23)

    // MARK: Device-dependent bits (NX_DEVICE*KEYMASK, low 16 bits)

    public static let deviceLeftControl  = Modifiers(rawValue: 0x0000_0001)
    public static let deviceLeftShift    = Modifiers(rawValue: 0x0000_0002)
    public static let deviceRightShift   = Modifiers(rawValue: 0x0000_0004)
    public static let deviceLeftCommand  = Modifiers(rawValue: 0x0000_0008)
    public static let deviceRightCommand = Modifiers(rawValue: 0x0000_0010)
    /// NX_DEVICELALTKEYMASK — left Option key is down.
    public static let deviceLeftOption   = Modifiers(rawValue: 0x0000_0020)
    /// NX_DEVICERALTKEYMASK — right Option key is down.
    public static let deviceRightOption  = Modifiers(rawValue: 0x0000_0040)
    public static let deviceRightControl = Modifiers(rawValue: 0x0000_2000)
}

/// A key event stripped down to what translation needs — a pure value type
/// so the translator is unit-testable without synthesizing NSEvents.
public struct KeyInput: Sendable, Hashable {
    /// macOS virtual keycode (`kVK_*` values; see `VirtualKey`).
    public var keyCode: UInt16
    /// NSEvent `characters`: the fully-composed characters (modifiers applied).
    public var characters: String?
    /// NSEvent `charactersIgnoringModifiers`: characters as if only Shift were
    /// held — Control and Option are stripped, Shift is *not* (Shift+1 → "!").
    public var charactersIgnoringModifiers: String?
    public var modifiers: Modifiers
    public var isARepeat: Bool

    public init(
        keyCode: UInt16,
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        modifiers: Modifiers = [],
        isARepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isARepeat = isARepeat
    }
}

/// What an Option key means when typing printable characters.
public enum OptionBehavior: Sendable, Hashable {
    /// macOS behavior: Option composes characters (é, ∂, dead keys). The
    /// event routes to the IME/`NSTextInputClient` path.
    case option
    /// Vim behavior: Option is Meta — emit `<M-x>` built from
    /// `charactersIgnoringModifiers`.
    case meta
}

/// Per-side Option policy (DESIGN.md §7.1). Default: left Option = Meta,
/// right Option = Option — so `<M-x>` mappings and `é`/`∂` both stay reachable.
public struct OptionPolicy: Sendable, Hashable {
    public var leftOption: OptionBehavior
    public var rightOption: OptionBehavior

    public init(leftOption: OptionBehavior = .meta, rightOption: OptionBehavior = .option) {
        self.leftOption = leftOption
        self.rightOption = rightOption
    }

    public static let `default` = OptionPolicy()

    /// Whether a pressed Option key acts as Meta for the given modifier state.
    ///
    /// The side is detected from the device-dependent bits
    /// (`NX_DEVICELALTKEYMASK`/`NX_DEVICERALTKEYMASK`). If both Options are
    /// down, Meta wins if *either* side's policy is `.meta`. If neither
    /// device bit is present (synthesized events), the left policy applies.
    public func optionActsAsMeta(for modifiers: Modifiers) -> Bool {
        guard modifiers.contains(.option) else { return false }
        let left = modifiers.contains(.deviceLeftOption)
        let right = modifiers.contains(.deviceRightOption)
        switch (left, right) {
        case (true, true):   return leftOption == .meta || rightOption == .meta
        case (true, false):  return leftOption == .meta
        case (false, true):  return rightOption == .meta
        case (false, false): return leftOption == .meta
        }
    }
}

/// The outcome of translating one key event.
public enum KeyTranslation: Sendable, Hashable {
    /// Send this string to `nvim_input` verbatim (already escaped/notated).
    case input(String)
    /// Route through `interpretKeyEvents(_:)` so `NSTextInputClient`/IME owns
    /// it (plain printable text, dead keys, marked-text composition).
    case passToIME
    /// Nothing to do (modifier-only key press, unmapped function hardware).
    case ignored
}
