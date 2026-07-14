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
private func button(in view: NSView, titled title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for subview in view.subviews {
        if let found = button(in: subview, titled: title) { return found }
    }
    return nil
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

    private func activeController(
        queryDebounce: Duration = .milliseconds(50)
    ) -> QuickOpenPanelController {
        let controller = QuickOpenPanelController(queryDebounce: queryDebounce)
        controller.present(over: nil)
        return controller
    }

    @Test func panelGeometryMatchesNorthstar() {
        let controller = QuickOpenPanelController()
        #expect(controller.panel.frame.size == NSSize(width: 498, height: 346))
        #expect(controller.tableView.rowHeight == 44)
        #expect(QuickOpenPanelController.searchRowHeight == 34)
    }

    @Test func displayShowsLiveCountAndSelectsFirstRow() {
        let controller = activeController()
        controller.display(results: makeResults(), totalCount: 32)

        #expect(controller.countLabel.stringValue == "32 files")
        #expect(controller.tableView.numberOfRows == 3)
        #expect(controller.selectedIndex == 0)
        #expect(controller.selectedPath == "src/pages/index.astro")

        controller.display(results: [], totalCount: 1)
        #expect(controller.countLabel.stringValue == "1 file")
    }

    @Test func cellsRenderTwoLinesWithFilenameAndDirectory() throws {
        let controller = activeController()
        controller.display(results: makeResults(), totalCount: 3)

        let cell = try #require(controller.tableView(
            controller.tableView,
            viewFor: controller.tableView.tableColumns[0],
            row: 0
        ))

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
        let controller = activeController()
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
        let controller = activeController()
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

    @Test func queryChangeCallbackIsDebouncedToLatestText() async throws {
        let controller = activeController(queryDebounce: .milliseconds(10))
        var queries: [String] = []
        controller.onQueryChange = { queries.append($0) }

        controller.searchField.stringValue = "i"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        controller.searchField.stringValue = "idx"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        await controller.waitForPendingQueryChange()
        #expect(queries == ["idx"])
    }

    @Test func closedSessionRejectsLateResults() {
        let controller = activeController()
        let generation = controller.presentationGeneration
        controller.close()

        let accepted = controller.display(
            results: makeResults(), totalCount: 3,
            presentationGeneration: generation)
        #expect(!accepted)
        #expect(controller.results.isEmpty)
        #expect(!controller.sessionActive)
    }

    @Test func countDistinguishesFilesMatchesAndTruncatedIndexes() {
        let controller = activeController()
        controller.display(results: makeResults(), totalCount: 50_000, isTruncated: true)
        #expect(controller.countLabel.stringValue == "50,000+ indexed")

        controller.display(
            results: makeResults(), totalCount: 50_000, isTruncated: true,
            matchingCount: 120)
        #expect(controller.countLabel.stringValue == "120 matches (partial)")
        #expect(controller.countLabel.toolTip?.contains("top 3") == true)

        controller.display(results: [], totalCount: 50_000, matchingCount: 0)
        #expect(controller.countLabel.stringValue == "0 matches")
    }

    @Test func panelClampsInsideSmallParentContent() {
        let parent = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = QuickOpenPanelController()
        controller.present(over: parent)

        let available = parent.convertToScreen(
            parent.contentView!.convert(parent.contentView!.bounds, to: nil))
        #expect(controller.panel.frame.width <= available.width)
        #expect(controller.panel.frame.height <= available.height)
        #expect(available.contains(controller.panel.frame))
        controller.close()
    }
}

// MARK: - FileTreeSidebarView

@Suite("FileTreeSidebarView", .serialized)
@MainActor
struct FileTreeSidebarTests {

    private func makeRefreshFixture(rootFileCount: Int = 0) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ShellKitRefresh-\(UUID().uuidString)")
        for directory in ["src/deep", "docs"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        for file in ["src/app.js", "src/deep/leaf.md", "docs/guide.md"] {
            fm.createFile(
                atPath: root.appendingPathComponent(file).path, contents: Data())
        }
        for index in 0..<rootFileCount {
            fm.createFile(
                atPath: root.appendingPathComponent(
                    String(format: "file-%03d.txt", index)).path,
                contents: Data())
        }
        return root
    }

    @Test func rendersRootRowsHeadless() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 600)
        )
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()
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

    @Test func expandingDirectoryRevealsChildren() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: NSRect(x: 0, y: 0, width: 370, height: 600))
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let srcRow = (0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "src"
        }
        let srcNode = sidebar.outlineView.item(atRow: try #require(srcRow)) as? FileTreeNode
        sidebar.outlineView.expandItem(srcNode)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(srcNode)
        #expect(sidebar.outlineView.numberOfRows == 4) // + app.js
    }

    @Test func rowSelectionAndDisclosureActionsRequestEditorFocus() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let srcRow = try #require((0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "src"
        })
        let fileRow = try #require((0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "main.swift"
        })
        let srcNode = try #require(
            sidebar.outlineView.item(atRow: srcRow) as? FileTreeNode)
        var focusRequests = 0
        var opened: [String] = []
        sidebar.onRequestEditorFocus = { focusRequests += 1 }
        sidebar.onOpenFile = { opened.append($0) }

        focusRequests = 0
        sidebar.performRowAction(row: srcRow, isDoubleClick: false)
        #expect(focusRequests == 1, "a directory row click must return focus")

        focusRequests = 0
        sidebar.performRowAction(row: fileRow, isDoubleClick: false)
        #expect(focusRequests == 1)
        #expect(opened.last == root.appendingPathComponent("main.swift").path)

        focusRequests = 0
        sidebar.outlineView.selectRowIndexes(
            IndexSet(integer: srcRow), byExtendingSelection: false)
        sidebar.outlineViewSelectionDidChange(Notification(
            name: NSOutlineView.selectionDidChangeNotification,
            object: sidebar.outlineView))
        #expect(focusRequests >= 1, "selection changes must return focus")

        focusRequests = 0
        #expect(sidebar.outlineView(sidebar.outlineView, shouldExpandItem: srcNode))
        #expect(focusRequests == 1, "disclosure expansion must return focus")

        focusRequests = 0
        #expect(sidebar.outlineView(sidebar.outlineView, shouldCollapseItem: srcNode))
        #expect(focusRequests == 1, "disclosure collapse must return focus")
        await sidebar.waitForPendingLoads()
    }

    @Test func failedInlineRenameRollsVisibleTextBackToModelName() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let row = try #require((0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "main.swift"
        })
        let node = try #require(sidebar.outlineView.item(atRow: row) as? FileTreeNode)
        var operations: [FileOperation] = []
        var focusRequests = 0
        sidebar.onFileOperation = { operations.append($0) }
        sidebar.onRequestEditorFocus = { focusRequests += 1 }

        sidebar.beginRename(of: node)
        let editingCell = try #require(sidebar.outlineView.view(
            atColumn: 0, row: row, makeIfNecessary: true) as? FileTreeCellView)
        editingCell.commitEditingName("invalid/name")

        #expect(editingCell.displayedName == "invalid/name")
        #expect(operations == [.rename(
            path: root.appendingPathComponent("main.swift").path,
            newName: "invalid/name")])
        #expect(focusRequests == 1)

        // Simulate the embedder's failure callback. No filesystem mutation
        // occurred, so reloading the row must restore the node's original name.
        #expect(sidebar.rollbackInlineRename(path: node.url.path))
        let rolledBackCell = try #require(sidebar.outlineView.view(
            atColumn: 0, row: row, makeIfNecessary: true) as? FileTreeCellView)
        #expect(rolledBackCell.displayedName == "main.swift")
    }

    @Test func hiddenFilesToggleReloads() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".env").path, contents: Data()
        )

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()
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

    @Test func contextMenuListsExpectedItems() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let menu = try #require(sidebar.outlineView.menu)
        sidebar.menuNeedsUpdate(menu)

        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [
            "New File", "New Folder", "Rename", "Move to Trash", "Reveal in Finder"
        ])
    }

    @Test func contextMenuActionsRequestNamesAndEmitOtherOperations() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()
        var operations: [FileOperation] = []
        var createDirectories: [String] = []
        var createKinds: [FileTreeCreateKind] = []
        sidebar.onFileOperation = { operations.append($0) }
        sidebar.onRequestCreateItem = { directory, kind in
            createDirectories.append(directory)
            createKinds.append(kind)
        }

        let menu = try #require(sidebar.outlineView.menu)
        sidebar.menuNeedsUpdate(menu)  // clickedRow == -1 → root node

        func fire(_ title: String) {
            let index = menu.items.firstIndex { $0.title == title }!
            menu.performActionForItem(at: index)
        }
        fire("New File")
        fire("New Folder")
        fire("Move to Trash")
        fire("Reveal in Finder")

        #expect(createDirectories == [
            root.standardizedFileURL.path, root.standardizedFileURL.path
        ])
        #expect(createKinds == [.file, .folder])
        #expect(operations == [
            .trash(path: root.standardizedFileURL.path),
            .revealInFinder(path: root.standardizedFileURL.path),
        ])
    }

    @Test func loadingAndFailureRowsAreVisibleAndRetryable() async throws {
        enum ListingFailure: Error { case unavailable }
        final class RecoveringLister: DirectoryLister, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0

            func list(_ url: URL) throws -> [DirectoryEntry] {
                let attempt = lock.withLock {
                    calls += 1
                    return calls
                }
                if attempt == 1 {
                    Thread.sleep(forTimeInterval: 0.03)
                    throw ListingFailure.unavailable
                }
                return [DirectoryEntry(name: "recovered.swift", isDirectory: false)]
            }
        }

        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidebar = FileTreeSidebarView(frame: .zero, lister: RecoveringLister())
        sidebar.setRoot(root)

        // An unloaded directory is represented immediately instead of
        // looking like an empty folder while its detached read is running.
        #expect(sidebar.outlineView.numberOfRows == 1)
        let loadingItem = try #require(sidebar.outlineView.item(atRow: 0))
        let loadingCell = try #require(sidebar.outlineView(
            sidebar.outlineView,
            viewFor: sidebar.outlineView.tableColumns[0],
            item: loadingItem))
        #expect(allStrings(in: loadingCell).contains("Loading…"))
        await sidebar.waitForPendingLoads()
        guard case .failed = sidebar.rootNode?.loadState else {
            Issue.record("Expected a failed directory state")
            return
        }

        let failureItem = try #require(sidebar.outlineView.item(atRow: 0))
        let failureCell = try #require(sidebar.outlineView(
            sidebar.outlineView,
            viewFor: sidebar.outlineView.tableColumns[0],
            item: failureItem))
        #expect(allStrings(in: failureCell).contains("Couldn’t load folder"))
        let retry = try #require(button(in: failureCell, titled: "Retry"))
        retry.performClick(nil)
        await sidebar.waitForPendingLoads()

        #expect(sidebar.rootNode?.loadState == .loaded)
        let recovered = sidebar.outlineView.item(atRow: 0) as? FileTreeNode
        #expect(recovered?.name == "recovered.swift")
    }

    @Test func changedPathsRefreshOnlyTheirExpandedLoadedParentOnce() async throws {
        let root = try makeRefreshFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 240), lister: lister)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        let deep = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src/deep").path))
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)

        let selectedPath = root.appendingPathComponent("src/app.js").path
        #expect(sidebar.selectItem(path: selectedPath))
        var focusRequests = 0
        sidebar.onRequestEditorFocus = { focusRequests += 1 }
        let callsBeforeRefresh = lister.listedPaths

        for name in ["new-a.swift", "new-b.swift"] {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("src/\(name)").path,
                contents: Data())
        }
        sidebar.reload(changedPaths: Set([
            root.appendingPathComponent("src/new-a.swift").path,
            root.appendingPathComponent("src/new-b.swift").path,
        ]))
        await sidebar.waitForPendingLoads()

        let refreshCalls = Array(lister.listedPaths.dropFirst(callsBeforeRefresh.count))
        #expect(refreshCalls == [root.appendingPathComponent("src").path])
        #expect(sidebar.rootNode?.findLoadedNode(path: src.url.path) === src)
        #expect(sidebar.rootNode?.findLoadedNode(path: deep.url.path) === deep)
        #expect(sidebar.outlineView.isItemExpanded(src))
        #expect(sidebar.outlineView.isItemExpanded(deep))
        #expect((sidebar.outlineView.item(atRow: sidebar.outlineView.selectedRow)
            as? FileTreeNode)?.url.path == selectedPath)
        #expect(focusRequests == 0, "layout restoration must not steal editor focus")
    }

    @Test func collapsedAndUnloadedBranchesAreNotEnumeratedByEvents() async throws {
        let root = try makeRefreshFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(frame: .zero, lister: lister)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let docs = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("docs").path))
        let callsAfterRoot = lister.totalCalls
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("docs/new.md").path, contents: Data())
        sidebar.reload(changedPaths: [root.appendingPathComponent("docs/new.md").path])
        await sidebar.waitForPendingLoads()
        #expect(docs.loadState == .unloaded)
        #expect(lister.totalCalls == callsAfterRoot)

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        let deep = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src/deep").path))
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)
        sidebar.outlineView.collapseItem(src)
        let callsAfterCollapse = lister.totalCalls
        let added = root.appendingPathComponent("src/deep/while-collapsed.swift")
        FileManager.default.createFile(atPath: added.path, contents: Data())
        sidebar.reload(changedPaths: [added.path])
        await sidebar.waitForPendingLoads()
        #expect(lister.totalCalls == callsAfterCollapse)

        // Expanding a previously loaded but stale branch refreshes it then,
        // and still does not enumerate any descendant directory.
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)
        #expect(Array(lister.listedPaths.dropFirst(callsAfterCollapse)) == [deep.url.path])
        #expect(sidebar.rootNode?.findLoadedNode(path: added.path) != nil)
    }

    @Test func revealingCreatedFolderLoadsAndExpandsUnloadedParent() async throws {
        let root = try makeRefreshFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 240), lister: lister)
        let window = NSWindow(
            contentRect: sidebar.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        #expect(src.loadState == .unloaded)
        let callsBeforeReveal = lister.listedPaths.count
        let created = root.appendingPathComponent("src/New Folder")
        try FileManager.default.createDirectory(
            at: created, withIntermediateDirectories: false)

        #expect(await sidebar.revealCreatedItem(path: created.path, focus: true))

        #expect(Array(lister.listedPaths.dropFirst(callsBeforeReveal)) == [src.url.path])
        #expect(src.loadState == .loaded)
        #expect(sidebar.outlineView.isItemExpanded(src))
        let selected = sidebar.outlineView.item(atRow: sidebar.outlineView.selectedRow)
            as? FileTreeNode
        #expect(selected?.url.path == created.path)
        let selectedRow = try #require(
            (0..<sidebar.outlineView.numberOfRows).first {
                (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.url.path
                    == created.path
            })
        #expect(sidebar.outlineView.visibleRect.intersects(
            sidebar.outlineView.rect(ofRow: selectedRow)))
        #expect(window.firstResponder === sidebar.outlineView)
        _ = window
    }

    @Test func revealingCreatedFolderPreservesUnrelatedExpandedBranches() async throws {
        let root = try makeRefreshFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 240), lister: lister)
        let window = NSWindow(
            contentRect: sidebar.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        let deep = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src/deep").path))
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)

        let docs = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("docs").path))
        sidebar.outlineView.expandItem(docs)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(docs)
        sidebar.outlineView.collapseItem(src)
        #expect(!sidebar.outlineView.isItemExpanded(src))
        #expect(sidebar.outlineView.isItemExpanded(docs))

        let callsBeforeReveal = lister.listedPaths.count
        let created = root.appendingPathComponent("src/New Folder")
        try FileManager.default.createDirectory(
            at: created, withIntermediateDirectories: false)

        #expect(await sidebar.revealCreatedItem(path: created.path, focus: true))

        #expect(Array(lister.listedPaths.dropFirst(callsBeforeReveal)) == [src.url.path])
        #expect(sidebar.rootNode?.findLoadedNode(path: src.url.path) === src)
        #expect(sidebar.rootNode?.findLoadedNode(path: deep.url.path) === deep)
        #expect(sidebar.rootNode?.findLoadedNode(path: docs.url.path) === docs)
        #expect(sidebar.outlineView.isItemExpanded(src))
        #expect(sidebar.outlineView.isItemExpanded(deep))
        #expect(sidebar.outlineView.isItemExpanded(docs))
        #expect((sidebar.outlineView.item(atRow: sidebar.outlineView.selectedRow)
            as? FileTreeNode)?.url.path == created.path)
        #expect(window.firstResponder === sidebar.outlineView)
        _ = window
    }

    @Test func droppedEventRescanRefreshesEveryVisibleLoadedDirectory() async throws {
        let root = try makeRefreshFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 240), lister: lister)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        let deep = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src/deep").path))
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)
        let callsBeforeRescan = lister.listedPaths.count

        sidebar.reload(changedPaths: [], requiresFullRescan: true)
        await sidebar.waitForPendingLoads()

        let rescanned = Array(lister.listedPaths.dropFirst(callsBeforeRescan))
        #expect(rescanned.count == 3)
        #expect(Set(rescanned) == Set([root.path, src.url.path, deep.url.path]))
        #expect(sidebar.outlineView.isItemExpanded(src))
        #expect(sidebar.outlineView.isItemExpanded(deep))
    }

    @Test func rootRefreshPreservesNestedExpansionSelectionAndScrollAnchor() async throws {
        let root = try makeRefreshFixture(rootFileCount: 80)
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 144), lister: lister)
        let window = NSWindow(
            contentRect: sidebar.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = sidebar
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let src = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src").path))
        sidebar.outlineView.expandItem(src)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(src)
        let deep = try #require(sidebar.rootNode?.findLoadedNode(
            path: root.appendingPathComponent("src/deep").path))
        sidebar.outlineView.expandItem(deep)
        await sidebar.waitForPendingLoads()
        sidebar.outlineView.expandItem(deep)
        let selectedPath = root.appendingPathComponent("src/deep/leaf.md").path
        #expect(sidebar.selectItem(path: selectedPath))

        sidebar.layoutSubtreeIfNeeded()
        sidebar.outlineView.layoutSubtreeIfNeeded()
        sidebar.outlineView.scrollRowToVisible(45)
        let clip = try #require(sidebar.outlineView.enclosingScrollView?.contentView)
        let topRowBefore = sidebar.outlineView.row(at: NSPoint(
            x: sidebar.outlineView.bounds.midX, y: clip.bounds.minY + 1))
        let topPathBefore = (sidebar.outlineView.item(atRow: topRowBefore)
            as? FileTreeNode)?.url.path
        let topOffsetBefore = clip.bounds.minY
            - sidebar.outlineView.rect(ofRow: topRowBefore).minY
        let callsBeforeRefresh = lister.totalCalls

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("aaa-new-root-file.txt").path,
            contents: Data())
        sidebar.reload(path: nil)
        await sidebar.waitForPendingLoads()

        let topRowAfter = sidebar.outlineView.row(at: NSPoint(
            x: sidebar.outlineView.bounds.midX, y: clip.bounds.minY + 1))
        let topPathAfter = (sidebar.outlineView.item(atRow: topRowAfter)
            as? FileTreeNode)?.url.path
        let topOffsetAfter = clip.bounds.minY
            - sidebar.outlineView.rect(ofRow: topRowAfter).minY
        #expect(lister.totalCalls == callsBeforeRefresh + 1)
        #expect(lister.listedPaths.last == root.path)
        #expect(sidebar.rootNode?.findLoadedNode(path: src.url.path) === src)
        #expect(sidebar.rootNode?.findLoadedNode(path: deep.url.path) === deep)
        #expect(sidebar.outlineView.isItemExpanded(src))
        #expect(sidebar.outlineView.isItemExpanded(deep))
        #expect((sidebar.outlineView.item(atRow: sidebar.outlineView.selectedRow)
            as? FileTreeNode)?.url.path == selectedPath)
        #expect(topPathAfter == topPathBefore)
        #expect(abs(topOffsetAfter - topOffsetBefore) < 0.5)
        _ = window
    }

    @Test func openFileCallbackAndReloadAfterOperation() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()
        #expect(sidebar.outlineView.numberOfRows == 3)

        // Simulate the embedder applying an operation, then reloading.
        try FileOperations.perform(.newFile(directory: root.path, name: "extra.txt"))
        sidebar.reload(path: root.path)
        await sidebar.waitForPendingLoads()
        #expect(sidebar.outlineView.numberOfRows == 4)

        sidebar.reload(path: nil)
        await sidebar.waitForPendingLoads()
        #expect(sidebar.outlineView.numberOfRows == 4)
    }
}

// MARK: - ⌘P stacking regression

@MainActor
@Suite struct QuickOpenScrimRegressionTests {
    private func scrimCount(in window: NSWindow) -> Int {
        window.contentView?.subviews.filter {
            $0.accessibilityIdentifier() == "quickopen.scrim"
        }.count ?? 0
    }

    @Test func representingNeverStacksScrims() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let controller = QuickOpenPanelController()
        controller.present(over: window)
        controller.present(over: window)
        controller.present(over: window)
        #expect(scrimCount(in: window) == 1, "repeated ⌘P must not pile scrims")
        controller.close()
        #expect(scrimCount(in: window) == 0, "close removes the scrim")
        controller.present(over: window)
        #expect(scrimCount(in: window) == 1, "fresh session installs exactly one")
        controller.close()
    }
}

// MARK: - Remote-sourced trees (no local filesystem behind the rows)

@Suite("FileTreeSidebarView remote sourcing", .serialized)
@MainActor
struct FileTreeSidebarRemoteTests {

    /// Counts list() calls per path; backed by the real local filesystem so
    /// the outline view sees ordinary listings.
    private final class CountingLister: DirectoryLister, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var listedPaths: [String] { lock.withLock { recorded } }

        func list(_ url: URL) async throws -> [DirectoryEntry] {
            lock.withLock { recorded.append(url.path) }
            return try await FileSystemLister().list(url)
        }

        func calls(for path: String) -> Int {
            listedPaths.filter { $0 == path }.count
        }
    }

    @Test func disabledFileOperationsSuppressTheWholeContextMenu() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sidebar = FileTreeSidebarView(frame: .zero)
        sidebar.allowsFileOperations = false
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let menu = try #require(sidebar.outlineView.menu)
        sidebar.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty, "every item is a local-FS mutation or Finder reveal")

        sidebar.allowsFileOperations = true
        sidebar.menuNeedsUpdate(menu)
        #expect(!menu.items.isEmpty)
    }

    @Test func refreshesOnExpandReListsALoadedDirectory() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()

        // Real frame + host window: the refresh path restores layout via
        // layoutSubtreeIfNeeded, which spins in temporary-engine Auto Layout
        // recursion for a zero-sized, windowless outline view.
        let sidebar = FileTreeSidebarView(
            frame: NSRect(x: 0, y: 0, width: 370, height: 400), lister: lister)
        let window = NSWindow(
            contentRect: sidebar.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = sidebar
        defer { window.orderOut(nil) }
        sidebar.refreshesOnExpand = true
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()

        let srcPath = root.appendingPathComponent("src").path
        let srcRow = try #require((0..<sidebar.outlineView.numberOfRows).first {
            (sidebar.outlineView.item(atRow: $0) as? FileTreeNode)?.name == "src"
        })
        let srcNode = try #require(sidebar.outlineView.item(atRow: srcRow) as? FileTreeNode)

        // First expansion: the ordinary lazy initial listing.
        sidebar.outlineView.expandItem(srcNode)
        await sidebar.waitForPendingLoads()
        #expect(lister.calls(for: srcPath) == 1)

        // Collapse and re-expand: no FSEvents marked src stale, but a tree
        // without change notifications must poll it again on expansion.
        sidebar.outlineView.collapseItem(srcNode)
        #expect(sidebar.outlineView(sidebar.outlineView, shouldExpandItem: srcNode))
        await sidebar.waitForPendingLoads()
        #expect(lister.calls(for: srcPath) == 2)

        // The local default keeps expansion I/O-free for loaded branches.
        sidebar.refreshesOnExpand = false
        #expect(sidebar.outlineView(sidebar.outlineView, shouldExpandItem: srcNode))
        await sidebar.waitForPendingLoads()
        #expect(lister.calls(for: srcPath) == 2)
    }
}
