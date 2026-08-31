// TreeSurfaceViewTests — docs/design/surface-navbar-v1.md §8/§10. Covers the
// render/diff contract, selection + scroll-reveal-only-on-change, active vs.
// secondary selection styling, context-menu filtering by row kind, inline
// create's provisional row, and the row-index == model-order projection
// invariant the runtime plugin relies on.
//
// CRITICAL project rule: never order a window onto the screen in tests. Any
// test that needs real layout (scrolling, row views materializing) hosts the
// view in a REAL-FRAMED NSWindow that is never shown.

import AppKit
import Testing
@testable import ShellKit

@MainActor
private func makeRow(
    _ id: String, _ label: String, depth: Int = 0,
    kind: TreeSurfaceRow.Kind = .file, expanded: Bool = false,
    badge: TreeSurfaceBadge? = nil, dotColorHex: String? = nil
) -> TreeSurfaceRow {
    TreeSurfaceRow(
        id: id, label: label, depth: depth, kind: kind, expanded: expanded,
        badge: badge, dotColorHex: dotColorHex)
}

@MainActor
private func makeModel(
    seq: Int = 1, headerTitle: String = "myproject",
    menu: [TreeSurfaceMenuItem] = [], rows: [TreeSurfaceRow]
) -> TreeSurfaceModel {
    TreeSurfaceModel(seq: seq, headerTitle: headerTitle, menu: menu, rows: rows)
}

/// Hosts a view in a real, never-shown window — required for anything that
/// exercises Auto Layout or row-view materialization (a zero-frame
/// windowless table spins AppKit's temporary layout engine).
@MainActor
private func hostInRealWindow(_ view: NSView, width: CGFloat = 260, height: CGFloat = 400) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled], backing: .buffered, defer: false)
    view.frame = window.contentView!.bounds
    window.contentView = view
    return window
}

@Suite("TreeSurfaceView render/diff", .serialized)
@MainActor
struct TreeSurfaceViewRenderTests {

    @Test func rendersRowsInModelOrderProjection() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let model = makeModel(rows: [
            makeRow("/root", "root", kind: .dir, expanded: true),
            makeRow("/root/a.swift", "a.swift", depth: 1),
            makeRow("/root/b.md", "b.md", depth: 1),
        ])
        view.render(model)

        // The load-bearing projection assumption: row index == model order
        // == the nvim buffer line the runtime plugin wrote.
        #expect(view.tableView.numberOfRows == model.rows.count)
        for (index, expected) in model.rows.enumerated() {
            #expect(view.displayedRows[index].id == expected.id)
        }
    }

    @Test func rerenderInsertsWithoutFullReload() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
            makeRow("/root/b.md", "b.md"),
        ]))
        #expect(view.tableView.numberOfRows == 2)

        // Simulate an expansion: a new row lands between the two existing
        // ones. Only their absolute paths carry identity across renders.
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
            makeRow("/root/a-child.txt", "a-child.txt", depth: 1),
            makeRow("/root/b.md", "b.md"),
        ]))

        #expect(view.tableView.numberOfRows == 3)
        #expect(view.displayedRows.map(\.id) == [
            "/root/a.swift", "/root/a-child.txt", "/root/b.md",
        ])
    }

    @Test func rerenderReloadsContentForUnchangedIdentity() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        view.render(makeModel(rows: [
            makeRow("/root", "root", kind: .dir, expanded: false),
        ]))
        #expect(view.displayedRows[0].expanded == false)

        // Same id, flipped `expanded` — an identity-preserving content
        // change (a directory toggling open), not an insert/remove.
        view.render(makeModel(rows: [
            makeRow("/root", "root", kind: .dir, expanded: true),
        ]))
        #expect(view.tableView.numberOfRows == 1)
        #expect(view.displayedRows[0].expanded == true)
    }

    @Test func degenerateChurnFallsBackToFullReloadAndPreservesRowCount() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let originalRows = (0..<10).map { makeRow("/root/file-\($0).txt", "file-\($0).txt") }
        view.render(makeModel(rows: originalRows))

        // Every id changes (a re-root): more than 50% churn, the degenerate
        // path — a full reload rather than 10 inserts + 10 removes.
        let replacedRows = (0..<10).map { makeRow("/new/other-\($0).txt", "other-\($0).txt") }
        view.render(makeModel(rows: replacedRows))

        #expect(view.tableView.numberOfRows == 10)
        #expect(view.displayedRows.map(\.id) == replacedRows.map(\.id))
    }

    @Test func headerTitleTracksModel() {
        let view = TreeSurfaceView(frame: .zero)
        view.render(makeModel(headerTitle: "superlemon", rows: []))
        #expect(view.displayedHeaderTitle == "superlemon")
    }
}

@Suite("TreeSurfaceView selection", .serialized)
@MainActor
struct TreeSurfaceViewSelectionTests {

    @Test func setSelectedRowDrivesTableSelection() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
            makeRow("/root/b.md", "b.md"),
        ]))
        view.setSelectedRow(1)
        #expect(view.selectedRow == 1)
        #expect(view.tableView.selectedRow == 1)

        view.setSelectedRow(nil)
        #expect(view.selectedRow == nil)
        #expect(view.tableView.selectedRow == -1)
    }

    @Test func scrollsToRevealOnlyWhenSelectedRowChanges() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let window = hostInRealWindow(view, height: 200)
        let rows = (0..<200).map { makeRow("/root/file-\($0).txt", "file-\($0).txt") }
        view.render(makeModel(rows: rows))
        view.layoutSubtreeIfNeeded()

        view.setSelectedRow(150)
        view.layoutSubtreeIfNeeded()
        let clip = view.tableView.enclosingScrollView!.contentView
        let revealedOrigin = clip.bounds.origin
        // Row 150 must actually be visible after the reveal.
        #expect(clip.documentVisibleRect.intersects(view.tableView.rect(ofRow: 150)))

        // Scroll away without going through setSelectedRow (as if the user
        // manually scrolled the navbar).
        clip.scroll(to: NSPoint(x: 0, y: 0))
        view.tableView.enclosingScrollView!.reflectScrolledClipView(clip)
        #expect(clip.bounds.origin != revealedOrigin)

        // Calling setSelectedRow again with the SAME row must not re-scroll.
        view.setSelectedRow(150)
        #expect(clip.bounds.origin == NSPoint(x: 0, y: 0),
            "re-selecting the same row must not scroll-to-reveal")

        // A genuinely different row DOES scroll.
        view.setSelectedRow(151)
        #expect(clip.documentVisibleRect.intersects(view.tableView.rect(ofRow: 151)))
        _ = window
    }
}

@Suite("TreeSurfaceView active state", .serialized)
@MainActor
struct TreeSurfaceViewActiveStateTests {

    @Test func setActiveTogglesEmphasizedRowStyling() throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let window = hostInRealWindow(view, height: 200)
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
            makeRow("/root/b.md", "b.md"),
        ]))
        view.layoutSubtreeIfNeeded()

        view.setActive(true)
        let emphasizedRow = try #require(
            view.tableView.rowView(atRow: 0, makeIfNecessary: true) as? FileTreeRowView)
        #expect(emphasizedRow.isRowEmphasized == true)

        view.setActive(false)
        let secondaryRow = try #require(
            view.tableView.rowView(atRow: 0, makeIfNecessary: true) as? FileTreeRowView)
        #expect(secondaryRow.isRowEmphasized == false)
        _ = window
    }
}

@Suite("TreeSurfaceView context menu", .serialized)
@MainActor
struct TreeSurfaceViewMenuTests {

    private func sampleMenu() -> [TreeSurfaceMenuItem] {
        [
            TreeSurfaceMenuItem(id: "new_file", title: "New File", forKinds: ["file", "dir", "root"]),
            TreeSurfaceMenuItem(id: "new_folder", title: "New Folder", forKinds: ["file", "dir", "root"]),
            TreeSurfaceMenuItem(id: "rename", title: "Rename", forKinds: ["file", "dir"]),
            TreeSurfaceMenuItem(id: "delete", title: "Move to Trash", forKinds: ["file", "dir"]),
            TreeSurfaceMenuItem(id: "reveal", title: "Reveal in Finder", forKinds: ["file", "dir", "root"]),
            TreeSurfaceMenuItem(id: "cd", title: "Change Working Directory", forKinds: ["dir", "up"]),
        ]
    }

    /// Right-clicks the given row so `NSTableView.clickedRow` targets it,
    /// mirroring FileTreeSidebarTests' `contextMenu` helper.
    private func contextMenu(
        in view: TreeSurfaceView, window: NSWindow, row: Int
    ) throws -> NSMenu {
        view.layoutSubtreeIfNeeded()
        let rowRect = view.tableView.rect(ofRow: row)
        let locationInWindow = view.tableView.convert(
            NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: locationInWindow,
            modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(view.tableView.menu(for: event))
        view.menuNeedsUpdate(menu)
        return menu
    }

    @Test func filtersMenuItemsByClickedRowKind() throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(menu: sampleMenu(), rows: [
            makeRow("/root/src", "src", kind: .dir),
            makeRow("/root/a.swift", "a.swift"),
        ]))

        let dirMenu = try contextMenu(in: view, window: window, row: 0)
        #expect(dirMenu.items.map(\.title) == [
            "New File", "New Folder", "Rename", "Move to Trash",
            "Reveal in Finder", "Change Working Directory",
        ])

        let fileMenu = try contextMenu(in: view, window: window, row: 1)
        #expect(fileMenu.items.map(\.title) == [
            "New File", "New Folder", "Rename", "Move to Trash", "Reveal in Finder",
        ])
        _ = window
    }

    @Test func rootAreaMenuUsesEmptyRowIDConvention() throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        view.render(makeModel(menu: sampleMenu(), rows: [
            makeRow("/root/src", "src", kind: .dir),
        ]))
        // clickedRow defaults to -1 until a real right-click on a row sets
        // it — exactly the "empty area" case the menu must treat as root.
        let menu = try #require(view.tableView.menu)
        view.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["New File", "New Folder", "Reveal in Finder"])

        var selectedItemIDs: [String] = []
        var selectedRowIDs: [String] = []
        view.onMenu = { itemID, rowID in
            selectedItemIDs.append(itemID)
            selectedRowIDs.append(rowID)
        }
        let index = try #require(menu.items.firstIndex { $0.title == "New File" })
        menu.performActionForItem(at: index)
        #expect(selectedItemIDs == ["new_file"])
        #expect(selectedRowIDs == [""])
    }
}

@Suite("TreeSurfaceView inline create", .serialized)
@MainActor
struct TreeSurfaceViewInlineCreateTests {

    @Test func beginCreateInsertsProvisionalRowUnderDirectory() throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(rows: [
            makeRow("/root/src", "src", kind: .dir, expanded: true),
            makeRow("/root/src/a.swift", "a.swift", depth: 1),
        ]))

        view.beginCreate(dirID: "/root/src", kind: .file)

        #expect(view.tableView.numberOfRows == 3)
        #expect(view.displayedRows[1].label == "")
        #expect(view.displayedRows[1].depth == 1)
        #expect(view.displayedRows[1].kind == .file)
        _ = window
    }

    @Test func beginCreateForUnknownDirInsertsAtTopAsRoot() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
        ]))

        // "/root" itself has no row in the flat list — beginCreate must
        // treat that as the root-insertion case (top of the list, depth 0).
        view.beginCreate(dirID: "/root", kind: .dir)

        #expect(view.tableView.numberOfRows == 2)
        #expect(view.displayedRows[0].depth == 0)
        #expect(view.displayedRows[0].kind == .dir)
        _ = window
    }

    @Test func emptyCommitCancelsAndRemovesProvisionalRow() throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
        ]))
        view.beginCreate(dirID: "/root", kind: .file)
        #expect(view.tableView.numberOfRows == 2)

        let cell = try #require(
            view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileTreeCellView)
        cell.commitEditingName("")

        #expect(view.tableView.numberOfRows == 1)
        #expect(view.displayedRows.map(\.id) == ["/root/a.swift"])
        _ = window
    }

    @Test func successfulCommitRemovesProvisionalRowAfterCallback() async throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(rows: [
            makeRow("/root/a.swift", "a.swift"),
        ]))
        view.beginCreate(dirID: "/root", kind: .file)

        var received: (dir: String, kind: TreeSurfaceRow.Kind, name: String)?
        view.onCreateCommit = { dir, kind, name in
            received = (dir, kind, name)
            return nil
        }
        let cell = try #require(
            view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileTreeCellView)
        cell.commitEditingName("new.txt")

        for _ in 0..<50 where received == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received?.dir == "/root")
        #expect(received?.kind == .file)
        #expect(received?.name == "new.txt")

        for _ in 0..<50 where view.tableView.numberOfRows != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.tableView.numberOfRows == 1)
        _ = window
    }

    @Test func failedCommitKeepsProvisionalRowOpenForRetry() async throws {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        let window = hostInRealWindow(view, height: 240)
        view.render(makeModel(rows: []))
        view.beginCreate(dirID: "/root", kind: .file)

        var attempts = 0
        view.onCreateCommit = { _, _, _ in
            attempts += 1
            return "already exists"
        }
        let cell = try #require(
            view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FileTreeCellView)
        cell.commitEditingName("dup.txt")

        for _ in 0..<50 where attempts == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(attempts == 1)
        // The row must still be there (not removed on failure) — the field
        // reopens for another attempt.
        #expect(view.tableView.numberOfRows == 1)
        _ = window
    }
}

@Suite("TreeSurfaceView clicks", .serialized)
@MainActor
struct TreeSurfaceViewClickTests {

    @Test func fileSingleClickOpensPreviewDoubleClickOpensPermanent() {
        let view = TreeSurfaceView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))
        var opened: [(String, Bool)] = []
        var rowClicks: [Int] = []
        view.onOpen = { id, permanent in opened.append((id, permanent)) }
        view.onRowClick = { rowClicks.append($0) }
        view.render(makeModel(rows: [makeRow("/root/a.swift", "a.swift")]))

        view.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        view.performRowAction(row: 0, isDoubleClick: false)
        #expect(rowClicks == [0])
        #expect(opened.count == 1 && opened[0] == ("/root/a.swift", false))

        view.performRowAction(row: 0, isDoubleClick: true)
        #expect(opened.count == 2)
        #expect(opened[0] == ("/root/a.swift", false))
        #expect(opened[1] == ("/root/a.swift", true))
        // The double-click leg does not re-fire onRowClick — it already
        // fired on the single-click leg of the same gesture.
        #expect(rowClicks == [0])
    }

    @Test func directorySingleClickOnlySelectsDoubleClickToggles() {
        let view = TreeSurfaceView(frame: .zero)
        var toggled: [String] = []
        var opened: [(String, Bool)] = []
        view.onToggle = { toggled.append($0) }
        view.onOpen = { id, permanent in opened.append((id, permanent)) }
        view.render(makeModel(rows: [makeRow("/root/src", "src", kind: .dir)]))

        view.performRowAction(row: 0, isDoubleClick: false)
        #expect(toggled.isEmpty)
        #expect(opened.isEmpty)

        view.performRowAction(row: 0, isDoubleClick: true)
        #expect(toggled == ["/root/src"])
        #expect(opened.isEmpty)
    }

    @Test func failedRowClickActivatesForRetry() {
        let view = TreeSurfaceView(frame: .zero)
        var opened: [(String, Bool)] = []
        view.onOpen = { id, permanent in opened.append((id, permanent)) }
        view.render(makeModel(rows: [makeRow("/root/broken", "", kind: .failed)]))

        view.performRowAction(row: 0, isDoubleClick: false)
        #expect(opened.count == 1 && opened[0] == ("/root/broken", false))
    }
}
