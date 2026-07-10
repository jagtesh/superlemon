// MouseTranslator tests — the mapping onto nvim_input_mouse arguments
// (DESIGN.md §7.4, `:h nvim_input_mouse`).

import Testing
@testable import InputKit

private let mouse = MouseTranslator()

@Suite("Mouse translation")
struct MouseTranslatorTests {

    @Test("plain left click")
    func leftClick() {
        let args = mouse.translate(
            button: .left, action: .press, modifiers: [],
            grid: 2, row: 10, col: 4, clickCount: 1
        )
        #expect(args == MouseInputArguments(
            button: "left", action: "press", modifier: "",
            grid: 2, row: 10, col: 4
        ))
    }

    @Test(
        "button and action names are nvim's",
        arguments: [
            (MouseButton.left, "left"),
            (MouseButton.right, "right"),
            (MouseButton.middle, "middle"),
        ],
        [
            (MouseAction.press, "press"),
            (MouseAction.drag, "drag"),
            (MouseAction.release, "release"),
        ]
    )
    func namesMatchNvim(
        _ button: (MouseButton, String), _ action: (MouseAction, String)
    ) {
        let args = mouse.translate(
            button: button.0, action: action.0, modifiers: [],
            grid: 1, row: 0, col: 0
        )
        #expect(args.button == button.1)
        #expect(args.action == action.1)
    }

    @Test(
        "modifier strings compose single chars in m,c,s,d order",
        arguments: [
            (Modifiers([.control]), "c"),
            (Modifiers([.command]), "d"),
            (Modifiers([.shift]), "s"),
            (Modifiers([.option]), "m"),
            (Modifiers([.control, .shift]), "cs"),
            (Modifiers([.control, .shift, .command]), "csd"),
            (Modifiers([.option, .control, .shift, .command]), "mcsd"),
        ]
    )
    func modifierStrings(_ pair: (Modifiers, String)) {
        let (mods, expected) = pair
        let args = mouse.translate(
            button: .left, action: .press, modifiers: mods,
            grid: 1, row: 3, col: 7
        )
        #expect(args.modifier == expected)
    }

    @Test("device-dependent option bits do not leak into the modifier string")
    func deviceBitsIgnored() {
        let args = mouse.translate(
            button: .left, action: .press,
            modifiers: [.option, .deviceLeftOption],
            grid: 1, row: 0, col: 0
        )
        #expect(args.modifier == "m")
    }

    @Test("double and triple clicks encode the count, like <2-LeftMouse>")
    func multiClickCounts() {
        let double = mouse.translate(
            button: .left, action: .press, modifiers: [],
            grid: 1, row: 5, col: 5, clickCount: 2
        )
        #expect(double.modifier == "2")

        let triple = mouse.translate(
            button: .left, action: .press, modifiers: [],
            grid: 1, row: 5, col: 5, clickCount: 3
        )
        #expect(triple.modifier == "3")

        // Modifier chars come first, count last: Ctrl+double-click → "c2".
        let ctrlDouble = mouse.translate(
            button: .left, action: .press, modifiers: [.control],
            grid: 1, row: 5, col: 5, clickCount: 2
        )
        #expect(ctrlDouble.modifier == "c2")
    }

    @Test("click counts beyond nvim's 4-click notation clamp to 4")
    func clickCountClamps() {
        let args = mouse.translate(
            button: .left, action: .press, modifiers: [],
            grid: 1, row: 0, col: 0, clickCount: 7
        )
        #expect(args.modifier == "4")
    }

    @Test("drag and release never carry a click count")
    func dragSequence() {
        // A double-click drag: press carries "2", the drag and release do not.
        let press = mouse.translate(
            button: .left, action: .press, modifiers: [],
            grid: 1, row: 5, col: 5, clickCount: 2
        )
        let drag = mouse.translate(
            button: .left, action: .drag, modifiers: [],
            grid: 1, row: 5, col: 9, clickCount: 2
        )
        let release = mouse.translate(
            button: .left, action: .release, modifiers: [],
            grid: 1, row: 5, col: 9, clickCount: 2
        )
        #expect(press.modifier == "2")
        #expect(drag == MouseInputArguments(
            button: "left", action: "drag", modifier: "",
            grid: 1, row: 5, col: 9
        ))
        #expect(release == MouseInputArguments(
            button: "left", action: "release", modifier: "",
            grid: 1, row: 5, col: 9
        ))
    }

    @Test("grid, row, col pass through untouched (multigrid coordinates)")
    func coordinatePassthrough() {
        let args = mouse.translate(
            button: .right, action: .press, modifiers: [.command],
            grid: 42, row: 99, col: 120
        )
        #expect((args.grid, args.row, args.col) == (42, 99, 120))
        #expect(args.modifier == "d")
    }

    @Test(
        "wheel steps become button \"wheel\" with a direction action",
        arguments: [
            (WheelDirection.up, "up"),
            (WheelDirection.down, "down"),
            (WheelDirection.left, "left"),
            (WheelDirection.right, "right"),
        ]
    )
    func wheelTranslation(_ pair: (WheelDirection, String)) {
        let (direction, action) = pair
        let args = mouse.translateWheel(
            direction: direction, modifiers: [.shift],
            grid: 3, row: 1, col: 2
        )
        #expect(args == MouseInputArguments(
            button: "wheel", action: action, modifier: "s",
            grid: 3, row: 1, col: 2
        ))
    }
}
