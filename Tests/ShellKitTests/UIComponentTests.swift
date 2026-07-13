// Tests for the ShellKit half of the superlemon.ui component framework
// (runtime/CONTRACT.md "superlemon.ui", DESIGN §15): hex color parsing,
// namespace-isolated sidebar decoration composition, statusbar plugin
// segments, and quick-open subtitle/positions rendering. All headless.

import AppKit
import Testing
@testable import ShellKit

// MARK: - Shared helpers

@MainActor
private func allStrings(in view: NSView) -> [String] {
    var strings: [String] = []
    if let field = view as? NSTextField {
        let value = field.attributedStringValue.string
        if !value.isEmpty { strings.append(value) }
    }
    for subview in view.subviews {
        strings.append(contentsOf: allStrings(in: subview))
    }
    return strings
}

// MARK: - "#RRGGBB" parsing

@Suite("UIColorHex")
struct UIColorHexTests {

    @Test func parsesHashRRGGBB() throws {
        let color = try #require(UIColorHex.parse("#E0B268")?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - CGFloat(0xE0) / 255) < 0.001)
        #expect(abs(color.greenComponent - CGFloat(0xB2) / 255) < 0.001)
        #expect(abs(color.blueComponent - CGFloat(0x68) / 255) < 0.001)
        #expect(color.alphaComponent == 1)
    }

    @Test func caseInsensitiveAndHashOptional() {
        #expect(UIColorHex.parse("#adc694") == UIColorHex.parse("#ADC694"))
        #expect(UIColorHex.parse("ADC694") == UIColorHex.parse("#ADC694"))
    }

    @Test(arguments: ["", "#", "#FFF", "#GGHHII", "#12345", "#1234567", "#+2B268", "not a color"])
    func rejectsMalformed(input: String) {
        #expect(UIColorHex.parse(input) == nil)
    }
}

// MARK: - Sidebar decoration composition

@Suite("SidebarDecorationStore")
struct SidebarDecorationStoreTests {

    private let red = NSColor.red
    private let blue = NSColor.blue

    @Test func laterSortedNamespaceWinsPerPath() {
        var store = SidebarDecorationStore()
        store.set(.init(kind: .badge("A"), color: red), path: "/p/x", namespace: "zeta")
        store.set(.init(kind: .badge("B"), color: blue), path: "/p/x", namespace: "alpha")

        // Composition is sorted by NAMESPACE NAME (not insertion order):
        // "zeta" > "alpha", so zeta's decoration wins for the shared path.
        #expect(store.composed["/p/x"] == SidebarDecoration(kind: .badge("A"), color: red))
    }

    @Test func nonConflictingPathsMerge() {
        var store = SidebarDecorationStore()
        store.set(.init(kind: .badge("A")), path: "/p/x", namespace: "one")
        store.set(.init(kind: .dot, color: red), path: "/p/y", namespace: "two")

        let composed = store.composed
        #expect(composed.count == 2)
        #expect(composed["/p/x"] == SidebarDecoration(kind: .badge("A")))
        #expect(composed["/p/y"] == SidebarDecoration(kind: .dot, color: red))
    }

    @Test func clearRemovesOnlyItsNamespace() {
        var store = SidebarDecorationStore()
        store.set(.init(kind: .badge("A")), path: "/p/x", namespace: "zeta")
        store.set(.init(kind: .badge("B")), path: "/p/x", namespace: "alpha")
        store.set(.init(kind: .dot), path: "/p/y", namespace: "alpha")

        store.clear(namespace: "zeta")
        let composed = store.composed
        // alpha's shadowed decoration for /p/x resurfaces; /p/y untouched.
        #expect(composed["/p/x"] == SidebarDecoration(kind: .badge("B")))
        #expect(composed["/p/y"] == SidebarDecoration(kind: .dot))

        store.clear(namespace: "alpha")
        #expect(store.composed.isEmpty)
    }

    @Test func setReplacesWithinNamespace() {
        var store = SidebarDecorationStore()
        store.set(.init(kind: .badge("1")), path: "/p/x", namespace: "ns")
        store.set(.init(kind: .badge("2")), path: "/p/x", namespace: "ns")
        #expect(store.composed["/p/x"] == SidebarDecoration(kind: .badge("2")))
    }
}

// MARK: - Sidebar rendering: ui decorations vs git badges

@Suite("FileTreeSidebarView ui decorations", .serialized)
@MainActor
struct SidebarUIDecorationTests {

    private func makeRoot() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ShellKitUI-\(UUID().uuidString)")
        try fm.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("a.swift").path, contents: Data())
        fm.createFile(atPath: root.appendingPathComponent("b.swift").path, contents: Data())
        return root
    }

    private func cellStrings(_ sidebar: FileTreeSidebarView, name: String) throws -> [String] {
        let row = try #require((0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == name
        })
        let item = sidebar.outlineView.item(atRow: row)!
        let cell = try #require(sidebar.outlineView(
            sidebar.outlineView, viewFor: sidebar.outlineView.tableColumns[0], item: item))
        return allStrings(in: cell)
    }

    @Test func uiDecorationWinsOverGitBadgeOnSamePath() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: NSRect(x: 0, y: 0, width: 370, height: 400))
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let aPath = root.standardizedFileURL.appendingPathComponent("a.swift").path
        let bPath = root.standardizedFileURL.appendingPathComponent("b.swift").path
        sidebar.setGitStatus([aPath: "M", bPath: "M"])
        sidebar.setUIDecorations([aPath: SidebarDecoration(kind: .badge("L3"))])

        // a.swift: ui decoration wins; the git "M" is not rendered.
        let aStrings = try cellStrings(sidebar, name: "a.swift")
        #expect(aStrings.contains("L3"))
        #expect(!aStrings.contains("M"))

        // b.swift: no ui decoration — the git badge still shows.
        #expect(try cellStrings(sidebar, name: "b.swift").contains("M"))
    }

    @Test func dotDecorationRendersOnDirectories() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let srcPath = root.standardizedFileURL.appendingPathComponent("src").path
        sidebar.setUIDecorations([srcPath: SidebarDecoration(kind: .dot, color: .systemGreen)])
        #expect(try cellStrings(sidebar, name: "src").contains("●"))
    }

    @Test func clearingDecorationsRestoresGitBadges() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let aPath = root.standardizedFileURL.appendingPathComponent("a.swift").path
        sidebar.setGitStatus([aPath: "M"])
        sidebar.setUIDecorations([aPath: SidebarDecoration(kind: .badge("!"))])
        #expect(try cellStrings(sidebar, name: "a.swift").contains("!"))

        sidebar.setUIDecorations([:])
        let strings = try cellStrings(sidebar, name: "a.swift")
        #expect(strings.contains("M"))
        #expect(!strings.contains("!"))
    }
}

// MARK: - Statusbar plugin segments

@Suite("StatusBarView plugin segments", .serialized)
@MainActor
struct StatusBarPluginSegmentTests {

    @Test func segmentsRenderComposedSortedByNamespace() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.render(StatusModel(), dark: false)
        bar.setPluginSegment(namespace: "zeta", text: "⚡ 3")
        bar.setPluginSegment(namespace: "alpha", text: "LSP ✓", color: .systemGreen)

        #expect(bar.pluginChipTexts == ["LSP ✓", "⚡ 3"])  // sorted by name
        let strings = allStrings(in: bar)
        #expect(strings.contains("⚡ 3"))
        #expect(strings.contains("LSP ✓"))
    }

    @Test func setReplacesAndClearRemovesOnlyItsNamespace() {
        let bar = StatusBarView(frame: .zero)
        bar.setPluginSegment(namespace: "a", text: "one")
        bar.setPluginSegment(namespace: "b", text: "two")
        bar.setPluginSegment(namespace: "a", text: "one′")

        #expect(bar.pluginChipTexts == ["one′", "two"])
        bar.clearPluginSegment(namespace: "a")
        #expect(bar.pluginChipTexts == ["two"])
        bar.clearPluginSegment(namespace: "b")
        #expect(bar.pluginChipTexts.isEmpty)
    }

    @Test func segmentsSurviveRenderAndStatuslineButHideDuringCommand() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.setPluginSegment(namespace: "ns", text: "⚡ 3")

        // A status re-render (every superlemon.status tick) keeps the chip.
        bar.render(StatusModel(file: "a.swift"), dark: false)
        #expect(allStrings(in: bar).contains("⚡ 3"))

        // Harvested-statusline mode: built-in chips yield, plugin chips stay.
        bar.renderStatusline([StatuslineSegment(text: "USER-LINE")])
        #expect(allStrings(in: bar).contains("⚡ 3"))
        let statuslineVisible = bar.subviews.contains {
            allStrings(in: $0).contains("USER-LINE")
        }
        #expect(statuslineVisible)

        // Command overlay: plugin chips hidden; restored when it clears.
        bar.renderStatusline(nil)
        bar.renderCommand(NSAttributedString(string: ":w"))
        // Chips live inside the stack view; find by identifier anywhere.
        func findChip(in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "status.plugin.ns" { return view }
            for sub in view.subviews {
                if let found = findChip(in: sub) { return found }
            }
            return nil
        }
        let chip = findChip(in: bar)
        #expect(chip?.isHidden == true)
        bar.renderCommand(nil)
        #expect(chip?.isHidden == false)
    }
}

// MARK: - QuickOpen subtitle rows (superlemon.ui palette)

@Suite("QuickOpenResult subtitle", .serialized)
@MainActor
struct QuickOpenSubtitleTests {

    private func activeController() -> QuickOpenPanelController {
        let controller = QuickOpenPanelController()
        controller.present(over: nil)
        return controller
    }

    @Test func subtitleRowRendersTitleWholeWithSubtitleBelow() throws {
        let controller = activeController()
        controller.display(
            results: [
                QuickOpenResult(path: "a.swift", subtitle: "Sources", positions: [0, 2])
            ],
            totalCount: 1)

        let cell = try #require(controller.tableView(
            controller.tableView, viewFor: controller.tableView.tableColumns[0], row: 0))
        let strings = allStrings(in: cell)
        #expect(strings.contains("a.swift"))  // title NOT split at "/"
        #expect(strings.contains("Sources"))
    }

    @Test func positionsBoldTheTitleLineWhenSubtitlePresent() throws {
        let controller = activeController()
        // A title containing "/" must still render whole (not path-split)
        // with positions indexing the full title.
        controller.display(
            results: [
                QuickOpenResult(path: "x/y title", subtitle: "sub", positions: [0, 2])
            ],
            totalCount: 1)
        let cell = try #require(controller.tableView(
            controller.tableView, viewFor: controller.tableView.tableColumns[0], row: 0)
            as? NSView)
        let title = try #require(
            allStrings(in: cell).first { $0 == "x/y title" },
            "title must render unsplit")
        #expect(title == "x/y title")

        let titleField = try #require(findField(in: cell, string: "x/y title"))
        let attributed = titleField.attributedStringValue
        func isBold(_ location: Int) -> Bool {
            let font = attributed.attribute(.font, at: location, effectiveRange: nil) as! NSFont
            return font.fontDescriptor.symbolicTraits.contains(.bold)
        }
        #expect(isBold(0) && isBold(2))
        #expect(!isBold(1) && !isBold(3))
    }

    @Test func classicRowsStillSplitPathAndCompareEqualWithoutSubtitle() {
        // Source-compatible: the old init produces subtitle == nil and the
        // classic two-line path rendering (covered by ViewSmokeTests).
        let old = QuickOpenResult(path: "src/a.swift", positions: [1])
        #expect(old.subtitle == nil)
        #expect(old == QuickOpenResult(path: "src/a.swift", subtitle: nil, positions: [1]))
    }

    @Test func emptySubtitleHidesSecondaryLine() throws {
        let controller = activeController()
        controller.display(
            results: [QuickOpenResult(path: "row", subtitle: "", positions: [])],
            totalCount: 1)
        let cell = try #require(controller.tableView(
            controller.tableView, viewFor: controller.tableView.tableColumns[0], row: 0))
        let pathField = try #require(fieldWithIdentifier(in: cell, "quickopen.cell.path"))
        #expect(pathField.isHidden)
    }

    @Test func openIndexFiresWithSelectedRowBeforeClose() {
        let controller = activeController()
        var events: [String] = []
        controller.onOpenIndex = { events.append("index:\($0)") }
        controller.onClose = { events.append("close") }
        controller.onOpen = { events.append("open:\($0)") }

        controller.display(
            results: [
                QuickOpenResult(path: "first", subtitle: "s"),
                QuickOpenResult(path: "second", subtitle: "s"),
            ],
            totalCount: 2)
        controller.moveSelection(by: 1)
        controller.openSelection()

        #expect(events == ["index:1", "open:second", "close"])
    }

    @Test func placeholderIsSettable() {
        let controller = QuickOpenPanelController()
        #expect(controller.placeholder == "Search files")
        controller.placeholder = "Buffers…"
        #expect(controller.placeholder == "Buffers…")
    }

    // Helpers

    private func findField(in view: NSView, string: String) -> NSTextField? {
        if let field = view as? NSTextField, field.attributedStringValue.string == string {
            return field
        }
        for sub in view.subviews {
            if let found = findField(in: sub, string: string) { return found }
        }
        return nil
    }

    private func fieldWithIdentifier(in view: NSView, _ identifier: String) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityIdentifier() == identifier {
            return field
        }
        for sub in view.subviews {
            if let found = fieldWithIdentifier(in: sub, identifier) { return found }
        }
        return nil
    }
}


// MARK: - Window-width forcing regression (the fzf/airline blowup)

@MainActor
@Suite struct StatusBarWindowForcingTests {
    /// An over-wide harvested statusline (airline + term://…fzf… names,
    /// literal %= fill runs) must CLIP inside the bar — never grow the
    /// window via required constraint chains (the 3x-window feedback loop).
    @Test func absurdStatuslineCannotGrowTheWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let bar = StatusBarView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        let monster = (0..<12).map { i in
            StatuslineSegment(
                text: "segment\(i) " + String(repeating: "x", count: 200)
                    + String(repeating: " ", count: 120),
                fg: 0xFFFFFF, bg: 0x004DC8)
        }
        bar.renderStatusline(monster)
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        #expect(window.frame.width == 600, "the bar must clip, not resize the window")
    }
}
