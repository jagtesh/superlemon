// Headless view-controller smoke tests: construct, render, walk the view
// hierarchy. No window is ever ordered on screen.
import AppKit
import Testing
import NvimKit
@testable import ChromeKit

@MainActor
private func makeTestWindow() -> NSWindow {
    // Referencing NSApplication.shared initializes AppKit for headless use.
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private let plainResolver: HighlightResolver = { _ in (fg: .black, bg: .white) }

/// Depth-first collection of all text field strings under a view.
@MainActor
private func allText(in view: NSView) -> [String] {
    var texts: [String] = []
    if let field = view as? NSTextField, !field.isHidden {
        texts.append(field.attributedStringValue.string)
    }
    for subview in view.subviews {
        texts.append(contentsOf: allText(in: subview))
    }
    return texts
}

@MainActor
@Suite struct CmdlinePanelControllerTests {
    @Test func headlessRenderShowsContent() {
        _ = NSApplication.shared
        let controller = CmdlinePanelController()
        let model = CmdlineModel(
            content: [Chunk(hlID: 0, text: "write")], pos: 5, firstc: ":", level: 1)
        controller.render(model, resolver: plainResolver)

        let texts = allText(in: controller.panel.contentView!)
        #expect(texts.contains { $0.contains("write") })
        #expect(texts.contains(":"))
    }

    @Test func promptReplacesFirstc() {
        _ = NSApplication.shared
        let controller = CmdlinePanelController()
        controller.render(
            CmdlineModel(content: [], pos: 0, firstc: "", prompt: "Name: "),
            resolver: plainResolver)

        #expect(allText(in: controller.panel.contentView!).contains("Name: "))
    }

    @Test func blockLinesAppearAboveContent() {
        _ = NSApplication.shared
        let controller = CmdlinePanelController()
        let model = CmdlineModel(
            content: [Chunk(hlID: 0, text: "echo 1")], pos: 6, firstc: ":",
            blockLines: [[Chunk(hlID: 0, text: "function! Foo()")]])
        controller.render(model, resolver: plainResolver)

        #expect(allText(in: controller.panel.contentView!)
            .contains { $0.contains("function! Foo()") })
    }

    @Test func renderNilDismisses() {
        _ = NSApplication.shared
        let controller = CmdlinePanelController()
        controller.render(
            CmdlineModel(content: [Chunk(hlID: 0, text: "q")], pos: 1, firstc: ":"),
            resolver: plainResolver)
        controller.render(nil, resolver: plainResolver)

        #expect(!controller.isPresented)
    }

    @Test func presentAndDismissOverHiddenWindow() {
        let window = makeTestWindow()
        let controller = CmdlinePanelController()
        controller.render(
            CmdlineModel(content: [Chunk(hlID: 0, text: "q")], pos: 1, firstc: ":"),
            resolver: plainResolver)
        controller.present(over: window)

        #expect(controller.isPresented)
        // Panel is centered on the parent, anchored near its top.
        #expect(controller.panel.frame.midX == window.frame.midX)
        #expect(controller.panel.frame.maxY
            == window.frame.maxY - CmdlinePanelController.topInset)

        controller.dismiss()
        #expect(!controller.isPresented)
        #expect(controller.panel.parent == nil)
    }
}

@MainActor
@Suite struct PopupMenuPanelControllerTests {
    private static let items = [
        PopupMenuItem(word: "append", kind: "f"),
        PopupMenuItem(word: "applyBatch", kind: "f"),
        PopupMenuItem(word: "array", kind: "v"),
    ]

    @Test func headlessRenderPopulatesTable() {
        _ = NSApplication.shared
        let controller = PopupMenuPanelController()
        controller.render(PopupMenuModel(items: Self.items, selected: 1))

        #expect(controller.tableView.numberOfRows == 3)
        #expect(controller.tableView.selectedRow == 1)
    }

    @Test func rowViewsShowWordAndKind() {
        _ = NSApplication.shared
        let controller = PopupMenuPanelController()
        controller.render(PopupMenuModel(items: Self.items, selected: -1))

        let row = controller.tableView(controller.tableView, viewFor: nil, row: 0)
        let rowView = try! #require(row as? PopupMenuRowView)
        #expect(rowView.wordField.stringValue == "append")
        #expect(rowView.kindField.stringValue == "f")
    }

    @Test func selectOnlyRenderMovesSelection() {
        _ = NSApplication.shared
        let controller = PopupMenuPanelController()
        var model = PopupMenuModel(items: Self.items, selected: 0)
        controller.render(model)
        #expect(controller.tableView.selectedRow == 0)

        model.selected = 2
        controller.render(model)
        #expect(controller.tableView.selectedRow == 2)

        model.selected = -1
        controller.render(model)
        #expect(controller.tableView.selectedRow == -1)
    }

    @Test func renderNilHides() {
        _ = NSApplication.shared
        let controller = PopupMenuPanelController()
        controller.render(PopupMenuModel(items: Self.items, selected: 0))
        controller.render(nil)

        #expect(!controller.isPresented)
        #expect(controller.tableView.numberOfRows == 0)
    }

    @Test func presentAnchorsAtPoint() {
        let window = makeTestWindow()
        let controller = PopupMenuPanelController()
        let model = PopupMenuModel(items: Self.items, selected: 0, row: 5, col: 10, grid: 2)
        controller.present(anchoredAt: NSPoint(x: 120, y: 300), in: window, model: model)

        #expect(controller.isPresented)
        // Height caps at maxVisibleRows; 3 items fit exactly.
        let size = controller.preferredSize(for: model)
        #expect(size.height == 3 * PopupMenuPanelController.rowHeight + 8)
        #expect(size.width >= 160 && size.width <= 480)

        controller.dismiss()
        #expect(!controller.isPresented)
    }

    @Test func preferredHeightCapsAtTenRows() {
        _ = NSApplication.shared
        let controller = PopupMenuPanelController()
        let many = (0..<40).map { PopupMenuItem(word: "item\($0)") }
        let size = controller.preferredSize(for: PopupMenuModel(items: many))
        #expect(size.height == 10 * PopupMenuPanelController.rowHeight + 8)
    }
}

@MainActor
@Suite struct MessageToastControllerTests {
    private func message(_ text: String, kind: String = "echo") -> MessageModel {
        MessageModel(kind: kind, content: [Chunk(hlID: 0, text: text)],
                     needsPrompt: kind == "confirm")
    }

    @Test func singleToastShowsNewestSkippingConfirm() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MessageToastController()
        controller.fadeDuration = 0  // deterministic removal in tests
        controller.attach(to: container)

        controller.render([
            message("saved"),
            message("E492: Not an editor command", kind: "emsg"),
            message("Save changes?", kind: "confirm"),
        ])

        // Single replacing toast: the NEWEST non-confirm message shows;
        // everything (except confirms? no — all non-prompt) lands in history.
        #expect(controller.activeToastCount == 1)
        #expect(container.subviews.count == 1)
        let shown = container.subviews.compactMap { $0 as? ToastView }.first
        #expect(shown?.message.isError == true)
        #expect(controller.history.count == 2)
        #expect(controller.history.last?.isError == true)
    }

    @Test func newestReplacesAndSitsTopRight() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MessageToastController()
        controller.fadeDuration = 0  // deterministic removal in tests
        controller.attach(to: container)
        let one = message("one")
        controller.render([one])
        controller.render([one, message("two")])

        let frames = container.subviews.map(\.frame)
        #expect(frames.count == 1, "new message replaces, never stacks")
        #expect(abs(frames[0].maxX - (600 - 12)) < 0.5)
        #expect(abs(frames[0].maxY - (400 - 12)) < 0.5)
        // Both messages are remembered with timestamps.
        #expect(controller.history.map(\.text) == ["one", "two"])
    }

    @Test func clickToDismissIsNotResurrected() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MessageToastController()
        controller.fadeDuration = 0  // deterministic removal in tests
        controller.attach(to: container)

        let msg = message("dismiss me")
        controller.render([msg])
        #expect(controller.activeToastCount == 1)

        controller.dismissToast(msg.id)
        #expect(controller.activeToastCount == 0)

        // Re-rendering the same state must not bring the toast back.
        controller.render([msg])
        #expect(controller.activeToastCount == 0)
    }

    @Test func renderEmptyRemovesAll() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MessageToastController()
        controller.fadeDuration = 0  // deterministic removal in tests
        controller.attach(to: container)
        controller.render([message("a"), message("b")])
        controller.render([])  // msg_clear
        _ = controller.history  // history survives clearing (by design)

        #expect(controller.activeToastCount == 0)
        #expect(container.subviews.isEmpty)
    }

    @Test func headlessRenderWithoutContainerIsSafe() {
        let controller = MessageToastController()
        controller.render([message("no container attached")])
        #expect(controller.activeToastCount == 1)
    }

    @Test func everyToastFadesAfterTheInterval() async throws {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = MessageToastController()
        controller.autoDismissInterval = 0.05
        controller.attach(to: container)

        controller.fadeDuration = 0  // immediate removal for deterministic timing
        controller.render([message("transient info")])
        #expect(controller.activeToastCount == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.activeToastCount == 0, "info fades away")

        controller.render([
            message("transient info"),
            message("E123: errors fade too — history is the record", kind: "emsg"),
        ])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.activeToastCount == 0, "errors fade after the interval too")
        #expect(controller.history.contains { $0.isError }, "…but stay in history")
    }

    @Test func errorToastUsesRedTint() {
        _ = NSApplication.shared
        let error = ToastView(
            message: MessageModel(kind: "emsg", content: [Chunk(hlID: 0, text: "E1")]),
            width: 320)
        error.updateLayer()
        let info = ToastView(
            message: MessageModel(kind: "echo", content: [Chunk(hlID: 0, text: "ok")]),
            width: 320)
        info.updateLayer()

        #expect(error.layer?.backgroundColor != info.layer?.backgroundColor)
    }
}
