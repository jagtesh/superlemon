import AppKit
import Testing
@testable import ShellKit

// MARK: - Hierarchy walking helpers

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

@MainActor
private func makeFixtureRoot() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("ShellKitViews-\(UUID().uuidString)")
    try fm.createDirectory(
        at: root.appendingPathComponent("src"), withIntermediateDirectories: true
    )
    fm.createFile(atPath: root.appendingPathComponent("main.swift").path, contents: Data())
    fm.createFile(atPath: root.appendingPathComponent("notes.md").path, contents: Data())
    fm.createFile(atPath: root.appendingPathComponent("src/app.js").path, contents: Data())
    return root
}

// MARK: - StatusBarView

@Suite("StatusBarView", .serialized)
@MainActor
struct StatusBarViewTests {

    private let model = StatusModel(
        mode: .normal, file: "docs/README.md", modified: true, branch: "main",
        line: 15, col: 9, totalLines: 310, project: "scopecreeplabs-site"
    )

    @Test func rendersAllChipsHeadless() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.render(model, dark: false)
        bar.layoutSubtreeIfNeeded()

        let strings = allStrings(in: bar)
        #expect(strings.contains("NORMAL"))
        #expect(strings.contains("README.md ●"))      // basename + modified dot
        #expect(strings.contains("⎇ main"))
        #expect(strings.contains("15:9"))
        #expect(strings.contains("scopecreeplabs-site"))
        #expect(bar.intrinsicContentSize.height == 24)
    }

    @Test func hidesBranchChipWhenBranchEmpty() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        var noBranch = model
        noBranch.branch = ""
        bar.render(noBranch, dark: false)
        #expect(!allStrings(in: bar).contains { $0.contains("⎇") })
    }

    @Test func unnamedBufferShowsNoNamePlaceholder() {
        let bar = StatusBarView(frame: .zero)
        bar.render(StatusModel(), dark: false)
        #expect(allStrings(in: bar).contains("[No Name]"))
    }

    @Test(arguments: [
        ("n", StatusMode.normal), ("niI", .normal), ("i", .insert), ("ic", .insert),
        ("v", .visual), ("V", .visual), ("\u{16}", .visual), ("c", .command),
        ("R", .replace), ("", .normal),
    ])
    func rawNvimModeMapping(raw: String, expected: StatusMode) {
        #expect(StatusMode(rawNvimMode: raw) == expected)
    }

    @Test func chipContrastFlipsInDarkMode() {
        // Light: saturated bg + white text; dark: pastel bg + dark text.
        let light = ShellPalette.modeBadge(.normal, dark: false)
        let dark = ShellPalette.modeBadge(.normal, dark: true)

        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB)!
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        #expect(luminance(light.background) < luminance(light.text))  // dark bg, white text
        #expect(luminance(dark.background) > luminance(dark.text))    // pastel bg, dark text
    }
}

// MARK: - QuickOpenPanelController

@Suite("QuickOpenPanelController", .serialized)
@MainActor
struct QuickOpenPanelTests {

    private func makeResults() -> [QuickOpenResult] {
        [
            QuickOpenResult(path: "src/pages/index.astro", positions: [10, 11, 12, 13, 14]),
            QuickOpenResult(path: "src/index.css", positions: [4, 5, 6, 7, 8]),
            QuickOpenResult(path: "README.md"),
        ]
    }

    @Test func panelGeometryMatchesNorthstar() {
        let controller = QuickOpenPanelController()
        #expect(controller.panel.frame.size == NSSize(width: 498, height: 346))
        #expect(controller.tableView.rowHeight == 44)
        #expect(QuickOpenPanelController.searchRowHeight == 34)
    }

    @Test func displayShowsLiveCountAndSelectsFirstRow() {
        let controller = QuickOpenPanelController()
        controller.display(results: makeResults(), totalCount: 32)

        #expect(controller.countLabel.stringValue == "32 files")
        #expect(controller.tableView.numberOfRows == 3)
        #expect(controller.selectedIndex == 0)
        #expect(controller.selectedPath == "src/pages/index.astro")

        controller.display(results: [], totalCount: 1)
        #expect(controller.countLabel.stringValue == "1 file")
    }

    @Test func cellsRenderTwoLinesWithFilenameAndDirectory() throws {
        let controller = QuickOpenPanelController()
        controller.display(results: makeResults(), totalCount: 3)

        let cell = try #require(controller.tableView(
            controller.tableView,
            viewFor: controller.tableView.tableColumns[0],
            row: 0
        ) as? NSView)

        let strings = allStrings(in: cell)
        #expect(strings.contains("index.astro"))   // primary line = basename
        #expect(strings.contains("src/pages"))     // secondary line = relative dir
    }

    @Test func matchedCharactersAreBolded() {
        // "idx" on "index.astro" → bold i, d(2), x(4) of the title line.
        let attributed = QuickOpenCellView.emphasized(
            "index.astro", positions: [0, 2, 4], size: 13, color: .black
        )
        func isBold(_ location: Int) -> Bool {
            let font = attributed.attribute(.font, at: location, effectiveRange: nil) as! NSFont
            return font.fontDescriptor.symbolicTraits.contains(.bold)
        }
        #expect(isBold(0) && isBold(2) && isBold(4))
        #expect(!isBold(1) && !isBold(3) && !isBold(5))
    }

    @Test func arrowKeysMoveSelectionWithClamping() {
        let controller = QuickOpenPanelController()
        controller.display(results: makeResults(), totalCount: 3)

        controller.moveSelection(by: 1)
        #expect(controller.selectedIndex == 1)
        controller.moveSelection(by: 1)
        controller.moveSelection(by: 1)   // clamps at last row
        #expect(controller.selectedIndex == 2)
        controller.moveSelection(by: -5)  // clamps at first row
        #expect(controller.selectedIndex == 0)
    }

    @Test func openSelectionFiresOnOpenThenOnClose() {
        let controller = QuickOpenPanelController()
        var opened: [String] = []
        var closed = 0
        controller.onOpen = { opened.append($0) }
        controller.onClose = { closed += 1 }

        controller.display(results: makeResults(), totalCount: 3)
        controller.moveSelection(by: 1)
        controller.openSelection()

        #expect(opened == ["src/index.css"])
        #expect(closed == 1)
    }

    @Test func presentInstallsScrimAndCloseRemovesIt() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        parent.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        let controller = QuickOpenPanelController()
        var closed = 0
        controller.onClose = { closed += 1 }
        controller.present(over: parent)

        let scrim = parent.contentView?.subviews.first {
            $0.accessibilityIdentifier() == "quickopen.scrim"
        }
        #expect(scrim != nil)
        // Upper-center: horizontally centered, top offset 96pt below content top.
        let panelFrame = controller.panel.frame
        #expect(abs(panelFrame.midX - parent.frame.midX) < 1)
        #expect(abs(parent.frame.maxY - 96 - panelFrame.maxY) < 1)

        controller.close()
        #expect(closed == 1)
        #expect(parent.contentView?.subviews.allSatisfy {
            $0.accessibilityIdentifier() != "quickopen.scrim"
        } == true)

        parent.orderOut(nil)
    }

    @Test func queryChangeCallbackFires() {
        let controller = QuickOpenPanelController()
        var queries: [String] = []
        controller.onQueryChange = { queries.append($0) }

        controller.searchField.stringValue = "idx"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        #expect(queries == ["idx"])
    }
}

// MARK: - FileTreeSidebarView

@Suite("FileTreeSidebarView", .serialized)
@MainActor
struct FileTreeSidebarTests {

    @Test func rendersRootRowsHeadless() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 600)
        )
        sidebar.setRoot(root)
        sidebar.outlineView.layoutSubtreeIfNeeded()

        #expect(sidebar.outlineView.numberOfRows == 3) // src, main.swift, notes.md
        #expect(sidebar.outlineView.rowHeight == 24)

        // Cell content via the delegate path (headless-safe).
        var names: [String] = []
        for row in 0..<sidebar.outlineView.numberOfRows {
            let item = sidebar.outlineView.item(atRow: row)!
            let cell = try #require(sidebar.outlineView(
                sidebar.outlineView, viewFor: sidebar.outlineView.tableColumns[0], item: item
            ))
            names.append(contentsOf: allStrings(in: cell))
        }
        #expect(names.contains("src"))
        #expect(names.contains("main.swift"))
        #expect(names.contains("notes.md"))
    }

    @Test func expandingDirectoryRevealsChildren() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: NSRect(x: 0, y: 0, width: 370, height: 600))
        sidebar.setRoot(root)

        let srcRow = (0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "src"
        }
        let srcNode = sidebar.outlineView.item(atRow: try #require(srcRow)) as? FileTreeNode
        sidebar.outlineView.expandItem(srcNode)
        #expect(sidebar.outlineView.numberOfRows == 4) // + app.js
    }

    @Test func hiddenFilesToggleReloads() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".env").path, contents: Data()
        )

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        #expect(sidebar.outlineView.numberOfRows == 3)
        sidebar.showsHiddenFiles = true
        #expect(sidebar.outlineView.numberOfRows == 4)
    }

    @Test func fileTypeDotColorsFollowPalette() {
        let swift = ShellPalette.fileTypeColor(forExtension: "swift", dark: false)
        let js = ShellPalette.fileTypeColor(forExtension: "js", dark: false)
        let other = ShellPalette.fileTypeColor(forExtension: "zig", dark: false)
        #expect(swift != js)
        #expect(js != other)
        #expect(ShellPalette.fileTypeColor(forExtension: "JSON", dark: false)
            == ShellPalette.fileTypeColor(forExtension: "json", dark: false))
    }

    @Test func contextMenuListsExpectedItems() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)

        let menu = try #require(sidebar.outlineView.menu)
        sidebar.menuNeedsUpdate(menu)

        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["New File", "New Folder", "Rename", "Delete", "Reveal in Finder"])
    }

    @Test func contextMenuActionsEmitFileOperations() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        var operations: [FileOperation] = []
        sidebar.onFileOperation = { operations.append($0) }

        let menu = try #require(sidebar.outlineView.menu)
        sidebar.menuNeedsUpdate(menu)  // clickedRow == -1 → root node

        func fire(_ title: String) {
            let index = menu.items.firstIndex { $0.title == title }!
            menu.performActionForItem(at: index)
        }
        fire("New File")
        fire("New Folder")
        fire("Delete")
        fire("Reveal in Finder")

        #expect(operations == [
            .newFile(directory: root.standardizedFileURL.path, name: "untitled"),
            .newFolder(directory: root.standardizedFileURL.path, name: "untitled folder"),
            .trash(path: root.standardizedFileURL.path),
            .revealInFinder(path: root.standardizedFileURL.path),
        ])
    }

    @Test func openFileCallbackAndReloadAfterOperation() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        #expect(sidebar.outlineView.numberOfRows == 3)

        // Simulate the embedder applying an operation, then reloading.
        try FileOperations.perform(.newFile(directory: root.path, name: "extra.txt"))
        sidebar.reload(path: root.path)
        #expect(sidebar.outlineView.numberOfRows == 4)

        sidebar.reload(path: nil)
        #expect(sidebar.outlineView.numberOfRows == 4)
    }
}
