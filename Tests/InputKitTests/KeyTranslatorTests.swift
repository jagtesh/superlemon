// KeyTranslator tests — these read as the specification of Superlemon's key
// language (DESIGN.md §7.1, `:h key-notation`).

import Testing
@testable import InputKit

// MARK: - Shared fixtures

private let translator = KeyTranslator()

/// Build a `KeyInput` tersely. `base` is `charactersIgnoringModifiers`
/// (Shift applied, Ctrl/Option stripped), `chars` is the composed string.
private func key(
    _ keyCode: UInt16 = 0,
    base: String? = nil,
    chars: String? = nil,
    mods: Modifiers = [],
    isARepeat: Bool = false
) -> KeyInput {
    KeyInput(
        keyCode: keyCode,
        characters: chars ?? base,
        charactersIgnoringModifiers: base,
        modifiers: mods,
        isARepeat: isARepeat
    )
}

/// Left Option pressed, with its device-dependent side bit.
private let leftOpt: Modifiers = [.option, .deviceLeftOption]
/// Right Option pressed, with its device-dependent side bit.
private let rightOpt: Modifiers = [.option, .deviceRightOption]

/// Every named special key: (virtual keycode, nvim key name).
private let specialKeys: [(UInt16, String)] = [
    (VirtualKey.escape, "Esc"),
    (VirtualKey.returnKey, "CR"),
    (VirtualKey.delete, "BS"),
    (VirtualKey.forwardDelete, "Del"),
    (VirtualKey.tab, "Tab"),
    (VirtualKey.upArrow, "Up"),
    (VirtualKey.downArrow, "Down"),
    (VirtualKey.leftArrow, "Left"),
    (VirtualKey.rightArrow, "Right"),
    (VirtualKey.home, "Home"),
    (VirtualKey.end, "End"),
    (VirtualKey.pageUp, "PageUp"),
    (VirtualKey.pageDown, "PageDown"),
    (VirtualKey.help, "Insert"),
    (VirtualKey.f1, "F1"), (VirtualKey.f2, "F2"), (VirtualKey.f3, "F3"),
    (VirtualKey.f4, "F4"), (VirtualKey.f5, "F5"), (VirtualKey.f6, "F6"),
    (VirtualKey.f7, "F7"), (VirtualKey.f8, "F8"), (VirtualKey.f9, "F9"),
    (VirtualKey.f10, "F10"), (VirtualKey.f11, "F11"), (VirtualKey.f12, "F12"),
    (VirtualKey.f13, "F13"), (VirtualKey.f14, "F14"), (VirtualKey.f15, "F15"),
    (VirtualKey.f16, "F16"), (VirtualKey.f17, "F17"), (VirtualKey.f18, "F18"),
    (VirtualKey.f19, "F19"), (VirtualKey.f20, "F20"),
    (VirtualKey.keypad0, "k0"), (VirtualKey.keypad1, "k1"),
    (VirtualKey.keypad2, "k2"), (VirtualKey.keypad3, "k3"),
    (VirtualKey.keypad4, "k4"), (VirtualKey.keypad5, "k5"),
    (VirtualKey.keypad6, "k6"), (VirtualKey.keypad7, "k7"),
    (VirtualKey.keypad8, "k8"), (VirtualKey.keypad9, "k9"),
    (VirtualKey.keypadDecimal, "kPoint"),
    (VirtualKey.keypadComma, "kComma"),
    (VirtualKey.keypadPlus, "kPlus"),
    (VirtualKey.keypadMinus, "kMinus"),
    (VirtualKey.keypadMultiply, "kMultiply"),
    (VirtualKey.keypadDivide, "kDivide"),
    (VirtualKey.keypadEnter, "kEnter"),
    (VirtualKey.keypadEquals, "kEqual"),
]

/// Modifier combinations and the canonical prefix each must produce on a
/// special key. Canonical order is M-, C-, S-, D- (nvim's mod_mask order).
/// On special keys, Option is always Meta — the IME has no use for
/// Option+Arrow — so plain `.option` (no device bits, no policy) yields M-.
private let modifierCombos: [(Modifiers, String)] = [
    ([], ""),
    ([.control], "C-"),
    ([.shift], "S-"),
    ([.option], "M-"),
    ([.command], "D-"),
    ([.control, .shift], "C-S-"),
    ([.option, .control], "M-C-"),
    ([.shift, .command], "S-D-"),
    ([.option, .command], "M-D-"),
    ([.control, .command], "C-D-"),
    ([.option, .control, .shift], "M-C-S-"),
    ([.control, .shift, .command], "C-S-D-"),
    ([.option, .control, .shift, .command], "M-C-S-D-"),
]

// MARK: - Special keys

@Suite("Special keys")
struct SpecialKeyTests {

    @Test(
        "every special key × every modifier combo → <mods-Name>",
        arguments: specialKeys, modifierCombos
    )
    func specialKeyMatrix(
        _ special: (UInt16, String), _ combo: (Modifiers, String)
    ) {
        let (keyCode, name) = special
        let (mods, prefix) = combo
        #expect(
            translator.translate(key(keyCode, mods: mods))
                == .input("<\(prefix)\(name)>")
        )
    }

    @Test("special keys translate even when they carry characters")
    func specialKeysIgnoreCharacterPayload() {
        // NSEvent gives Return characters "\r", Tab "\t", Esc "\u{1B}" — the
        // keycode wins.
        #expect(translator.translate(key(VirtualKey.returnKey, base: "\r")) == .input("<CR>"))
        #expect(translator.translate(key(VirtualKey.tab, base: "\t")) == .input("<Tab>"))
        #expect(translator.translate(key(VirtualKey.escape, base: "\u{1B}")) == .input("<Esc>"))
        #expect(translator.translate(key(VirtualKey.delete, base: "\u{7F}")) == .input("<BS>"))
    }

    @Test("Option side and policy are irrelevant on special keys — always M-")
    func optionAlwaysMetaOnSpecials() {
        let bothAsOption = OptionPolicy(leftOption: .option, rightOption: .option)
        #expect(
            translator.translate(
                key(VirtualKey.leftArrow, mods: rightOpt), policy: bothAsOption
            ) == .input("<M-Left>")
        )
    }

    @Test("key repeats translate identically")
    func repeatsTranslate() {
        #expect(
            translator.translate(key(VirtualKey.downArrow, isARepeat: true))
                == .input("<Down>")
        )
    }

    @Test("keypad Clear has no nvim name and is ignored")
    func keypadClearIgnored() {
        #expect(translator.translate(key(VirtualKey.keypadClear)) == .ignored)
    }
}

// MARK: - Printable characters: IME routing

@Suite("Printable routing")
struct PrintableRoutingTests {

    @Test(
        "plain printables belong to the IME",
        arguments: ["a", "A", "1", "!", ";", "é", "あ", " "]
    )
    func plainPrintablesPassToIME(_ ch: String) {
        #expect(translator.translate(key(0, base: ch)) == .passToIME)
    }

    @Test("Shift alone never forces translation — 'A' is just text")
    func shiftedPrintablePassesToIME() {
        #expect(
            translator.translate(key(0, base: "A", mods: .shift)) == .passToIME
        )
        // Shift+Space too: the shift is meaningless, the space is text.
        #expect(
            translator.translate(key(VirtualKey.space, base: " ", mods: .shift))
                == .passToIME
        )
    }

    @Test("Caps Lock alone never forces translation")
    func capsLockPassesToIME() {
        #expect(
            translator.translate(key(0, base: "A", mods: .capsLock))
                == .passToIME
        )
    }

    @Test("dead keys (empty characters, no chord) go to the IME")
    func deadKeysPassToIME() {
        // Option-e on a US keyboard (dead acute) delivers empty strings; the
        // IME must own it so the next vowel composes.
        #expect(
            translator.translate(
                key(0x0E, base: "", chars: "", mods: rightOpt)
            ) == .passToIME
        )
    }

    @Test("chorded event with no characters at all is ignored")
    func chordedCharacterlessIgnored() {
        #expect(
            translator.translate(key(0x0E, base: "", chars: "", mods: .control))
                == .ignored
        )
    }
}

// MARK: - Ctrl and Cmd chords

@Suite("Ctrl and Cmd chords")
struct ChordTests {

    @Test("Ctrl chords always translate, never IME")
    func ctrlChord() {
        // NSEvent delivers characters "\u{01}" for Ctrl-A;
        // charactersIgnoringModifiers is "a".
        #expect(
            translator.translate(key(0, base: "a", chars: "\u{01}", mods: .control))
                == .input("<C-a>")
        )
        #expect(
            translator.translate(key(0, base: "w", mods: .control))
                == .input("<C-w>")
        )
    }

    @Test("Ctrl+Shift+letter is <C-S-a>: S- modifier + lowercase base")
    func ctrlShiftLetter() {
        // <C-A> and <C-a> are the same key to nvim; the S- form is the only
        // way to express ctrl+shift+a.
        #expect(
            translator.translate(
                key(0, base: "A", mods: [.control, .shift])
            ) == .input("<C-S-a>")
        )
    }

    @Test("Shift absorbed into a symbol needs no S-: Ctrl+Shift+1 is <C-!>")
    func ctrlShiftSymbol() {
        #expect(
            translator.translate(
                key(0x12, base: "!", mods: [.control, .shift])
            ) == .input("<C-!>")
        )
    }

    @Test("Cmd chords produce <D-x> from the lowercased base")
    func cmdChord() {
        #expect(
            translator.translate(key(0x01, base: "s", mods: .command))
                == .input("<D-s>")
        )
    }

    @Test("Cmd+Shift+letter is <S-D-s>")
    func cmdShiftChord() {
        #expect(
            translator.translate(key(0x01, base: "S", mods: [.command, .shift]))
                == .input("<S-D-s>")
        )
    }

    @Test("Caps Lock does not fake a shifted chord: Cmd+A(caps) is <D-a>")
    func cmdWithCapsLock() {
        #expect(
            translator.translate(
                key(0, base: "A", mods: [.command, .capsLock])
            ) == .input("<D-a>")
        )
    }

    @Test("Ctrl+Cmd compose in canonical order: <C-D-a>")
    func ctrlCmdChord() {
        #expect(
            translator.translate(key(0, base: "a", mods: [.control, .command]))
                == .input("<C-D-a>")
        )
    }

    @Test("Space chords use the Space key name")
    func spaceChords() {
        #expect(
            translator.translate(
                key(VirtualKey.space, base: " ", mods: .control)
            ) == .input("<C-Space>")
        )
        #expect(
            translator.translate(
                key(VirtualKey.space, base: " ", mods: .command)
            ) == .input("<D-Space>")
        )
        #expect(
            translator.translate(
                key(VirtualKey.space, base: " ", mods: [.control, .shift])
            ) == .input("<C-S-Space>")
        )
    }

    @Test(
        "notation-colliding characters use nvim key names inside chords",
        arguments: [
            ("<", "<C-lt>"),
            ("|", "<C-Bar>"),
            ("\\", "<C-Bslash>"),
        ]
    )
    func chordCharacterNames(_ pair: (String, String)) {
        let (base, expected) = pair
        #expect(
            translator.translate(key(0, base: base, mods: .control))
                == .input(expected)
        )
    }
}

// MARK: - Option policy

@Suite("Option policy")
struct OptionPolicyTests {

    @Test("default policy: left Option is Meta → <M-a>")
    func leftOptionMetaByDefault() {
        // charactersIgnoringModifiers strips Option: base "a", composed "å".
        #expect(
            translator.translate(key(0, base: "a", chars: "å", mods: leftOpt))
                == .input("<M-a>")
        )
    }

    @Test("default policy: right Option types characters → IME")
    func rightOptionTypesByDefault() {
        #expect(
            translator.translate(key(0x0E, base: "e", chars: "´", mods: rightOpt))
                == .passToIME
        )
    }

    @Test("side detection reads the NX device bits, not the keycode")
    func sideDetectionUsesDeviceBits() {
        let flipped = OptionPolicy(leftOption: .option, rightOption: .meta)
        #expect(
            translator.translate(key(0, base: "a", chars: "å", mods: leftOpt), policy: flipped)
                == .passToIME
        )
        #expect(
            translator.translate(key(0, base: "a", chars: "å", mods: rightOpt), policy: flipped)
                == .input("<M-a>")
        )
    }

    @Test("both Options as Meta")
    func bothMeta() {
        let policy = OptionPolicy(leftOption: .meta, rightOption: .meta)
        #expect(
            translator.translate(key(0, base: "x", mods: rightOpt), policy: policy)
                == .input("<M-x>")
        )
    }

    @Test("both Options as Option: everything printable goes to the IME")
    func bothOption() {
        let policy = OptionPolicy(leftOption: .option, rightOption: .option)
        #expect(
            translator.translate(key(0, base: "x", mods: leftOpt), policy: policy)
                == .passToIME
        )
    }

    @Test("both sides held: Meta wins if either side is .meta")
    func bothSidesHeldMetaWins() {
        let mods: Modifiers = [.option, .deviceLeftOption, .deviceRightOption]
        #expect(
            translator.translate(key(0, base: "a", mods: mods))
                == .input("<M-a>")
        )
    }

    @Test("no device bits (synthesized event): left-side policy applies")
    func missingDeviceBitsFallBackToLeft() {
        #expect(
            translator.translate(key(0, base: "a", mods: .option))
                == .input("<M-a>")  // default left = .meta
        )
        let bothAsOption = OptionPolicy(leftOption: .option, rightOption: .option)
        #expect(
            translator.translate(key(0, base: "a", mods: .option), policy: bothAsOption)
                == .passToIME
        )
    }

    @Test("Option-as-Meta letters honor the Shift rule: <M-S-a>")
    func metaShiftLetter() {
        #expect(
            translator.translate(key(0, base: "A", mods: leftOpt.union(.shift)))
                == .input("<M-S-a>")
        )
    }

    @Test("Ctrl/Cmd in the chord force Option to Meta even on an .option side")
    func chordOverridesOptionPolicy() {
        // The IME can never own a Ctrl/Cmd chord, so Option contributes M-
        // regardless of side policy. Canonical order puts M first: <M-D-s>.
        #expect(
            translator.translate(key(0x01, base: "s", mods: rightOpt.union(.command)))
                == .input("<M-D-s>")
        )
        #expect(
            translator.translate(key(0, base: "a", mods: rightOpt.union(.control)))
                == .input("<M-C-a>")
        )
    }
}

// MARK: - Modifier-only events

@Suite("Modifier-only events")
struct ModifierOnlyTests {

    @Test(
        "a modifier key by itself is ignored",
        arguments: [
            VirtualKey.command, VirtualKey.rightCommand,
            VirtualKey.shift, VirtualKey.rightShift,
            VirtualKey.option, VirtualKey.rightOption,
            VirtualKey.control, VirtualKey.rightControl,
            VirtualKey.capsLock, VirtualKey.functionKey,
        ]
    )
    func modifierKeysIgnored(_ keyCode: UInt16) {
        #expect(translator.translate(key(keyCode, mods: .shift)) == .ignored)
    }
}

// MARK: - Escaping literal text

@Suite("Input escaping")
struct EscapingTests {

    @Test("< becomes <lt> in literal text (the insertText commit path)")
    func escapesLessThan() {
        #expect(KeyTranslator.escapeForInput("a<b<c") == "a<lt>b<lt>c")
        #expect(KeyTranslator.escapeForInput("<Esc>") == "<lt>Esc>")
    }

    @Test("everything else passes through untouched")
    func leavesOtherTextAlone() {
        #expect(KeyTranslator.escapeForInput("hello, wörld! 🍋 >|\\") == "hello, wörld! 🍋 >|\\")
        #expect(KeyTranslator.escapeForInput("") == "")
    }

    @Test("already-escaped text is escaped again, not double-parsed")
    func escapingIsMechanical() {
        // nvim_input would interpret "<lt>"; a literal "<lt>" typed by the
        // user must arrive as "<lt>lt>".
        #expect(KeyTranslator.escapeForInput("<lt>") == "<lt>lt>")
    }
}
