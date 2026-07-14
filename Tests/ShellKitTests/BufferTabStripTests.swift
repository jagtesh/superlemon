import AppKit
import Testing
@testable import ShellKit

// MARK: - Helpers

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

private func luminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB)!
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
}

// MARK: - BufferTabStripView

@Suite("BufferTabStripView", .serialized)
@MainActor
struct BufferTabStripTests {

    private let tabs = [
        BufferTab(bufnr: 1, name: "Sources/ShellKit/StatusBarView.swift", modified: false),
        BufferTab(bufnr: 3, name: "docs/README.md", modified: true),
        BufferTab(bufnr: 7, name: "", modified: false),
    ]

    private func makeStrip(width: CGFloat = 900) -> BufferTabStripView {
        let strip = BufferTabStripView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        strip.render(tabs: tabs, current: 3, dark: false)
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    @Test func rendersBasenameLabelsAndFullNameTooltips() {
        let strip = makeStrip()

        #expect(strip.intrinsicContentSize.height == 28)
        #expect(BufferTabStripView.stripHeight == 28)

        let items = strip.tabItems
        #expect(items.map(\.bufnr) == [1, 3, 7])
        #expect(items[0].label.stringValue == "StatusBarView.swift")
        #expect(items[0].toolTip == "Sources/ShellKit/StatusBarView.swift")
        #expect(items[1].toolTip == "docs/README.md")
        #expect(items[2].label.stringValue == "[No Name]")
        #expect(items[2].toolTip == nil)
    }

    @Test func modifiedTabShowsDotBeforeLabel() {
        let items = makeStrip().tabItems
        #expect(items[1].label.stringValue == "● README.md")
        #expect(!items[0].label.stringValue.contains("●"))
    }

    @Test func activeTabIsDistinctFromInactive() {
        let items = makeStrip().tabItems
        let active = items[1]   // bufnr 3 == current
        let inactive = items[0]

        #expect(active.isActive)
        #expect(!inactive.isActive)
        // Active: opaque fill + primary text; inactive: no fill + secondary text.
        #expect(active.layer?.backgroundColor != inactive.layer?.backgroundColor)
        #expect(inactive.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(active.label.textColor != inactive.label.textColor)
        #expect(active.accessibilityIdentifier() == "tab.3")
    }

    @Test func tabsExposeSelectionLabelsAndActionsToAccessibility() throws {
        let strip = makeStrip()
        let active = strip.tabItems[1]

        #expect(strip.accessibilityRole() == .tabGroup)
        #expect(strip.accessibilityLabel() == "Open buffers")
        #expect(active.accessibilityRole() == .radioButton)
        #expect(active.isAccessibilitySelected())
        #expect(active.accessibilityLabel() == "README.md, modified")
        #expect(active.closeButton.accessibilityLabel() == "Close README.md")

        var selected: [Int] = []
        active.onSelect = { selected.append($0) }
        #expect(active.accessibilityPerformPress())
        #expect(selected == [3])
    }

    @Test func selectAndCloseCallbacksCarryBufnr() {
        let strip = makeStrip()
        var selected: [Int] = []
        var closed: [Int] = []
        strip.onSelect = { selected.append($0) }
        strip.onClose = { closed.append($0) }

        let items = strip.tabItems
        items[0].performSelect()          // body click
        items[2].performSelect()
        items[1].closeButton.performClick(nil)  // ✕ click

        #expect(selected == [1, 7])
        #expect(closed == [3])
    }

    @Test func tabWidthIsCappedAt220() {
        let strip = BufferTabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        strip.render(
            tabs: [BufferTab(
                bufnr: 1,
                name: "a/very/deep/path/AnExtraordinarilyLongViewControllerFileName+Extensions.swift"
            )],
            current: 1, dark: false
        )
        strip.layoutSubtreeIfNeeded()
        #expect(strip.tabItems[0].frame.width <= 220)
    }

    @Test func overflowEmbedsInHiddenScrollerScrollViewWithoutCrash() {
        let strip = BufferTabStripView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let many = (1...40).map {
            BufferTab(bufnr: $0, name: "Sources/Deep/Path/File\($0).swift", modified: $0 % 3 == 0)
        }
        strip.render(tabs: many, current: 20, dark: false)
        strip.layoutSubtreeIfNeeded()

        #expect(strip.tabItems.count == 40)

        let scrollView = strip.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scrollView != nil)
        #expect(scrollView?.hasHorizontalScroller == false)
        #expect(scrollView?.horizontalScrollElasticity == NSScrollView.Elasticity.none)
        // Content overflows the 300pt strip horizontally instead of wrapping.
        let documentWidth = scrollView?.documentView?.frame.width ?? 0
        #expect(documentWidth > 300)
        #expect((scrollView?.documentView?.frame.height ?? 0) <= 28)

        strip.ensureCurrentTabVisible()
        let active = strip.tabItems.first { $0.isActive }!
        let activeRect = active.convert(active.bounds, to: scrollView?.documentView)
        #expect(scrollView?.contentView.bounds.intersects(activeRect) == true)
    }

    @Test func appearanceFlipChangesStripAndLabelColors() {
        let strip = makeStrip()
        let lightBand = strip.layer?.backgroundColor
        let lightLabel = strip.tabItems[0].label.textColor

        strip.applyAppearance(dark: true)
        let darkBand = strip.layer?.backgroundColor
        let darkLabel = strip.tabItems[0].label.textColor

        #expect(lightBand != darkBand)
        #expect(lightLabel != darkLabel)
        // Band goes darker; inactive label goes lighter (NORTHSTAR §2.2).
        #expect(luminance(ShellPalette.titlebarBackground(dark: true))
            < luminance(ShellPalette.titlebarBackground(dark: false)))
        #expect(luminance(ShellPalette.tabInactiveText(dark: true))
            > luminance(ShellPalette.tabInactiveText(dark: false)))
        // State survives the flip.
        #expect(strip.tabItems[1].isActive)
        #expect(strip.tabItems[1].label.stringValue == "● README.md")
    }

    @Test func rerenderReplacesTabsIdempotently() {
        let strip = makeStrip()
        strip.render(tabs: [BufferTab(bufnr: 9, name: "only.txt")], current: 9, dark: false)
        #expect(strip.tabItems.count == 1)
        #expect(strip.tabItems[0].isActive)

        strip.render(tabs: [], current: -1, dark: false)
        #expect(strip.tabItems.isEmpty)
    }

    @Test func accessoryButtonsExistAndFireToggleCallbacks() {
        let strip = makeStrip()
        #expect(strip.sidebarButton.accessibilityIdentifier() == "tabstrip.toggleSidebar")
        #expect(strip.minimapButton.accessibilityIdentifier() == "tabstrip.toggleMinimap")
        #expect(strip.sidebarButton.accessibilityLabel() == "Toggle Sidebar")
        #expect(strip.minimapButton.accessibilityLabel() == "Toggle Minimap")

        var sidebarToggles = 0
        var minimapToggles = 0
        strip.onToggleSidebar = { sidebarToggles += 1 }
        strip.onToggleMinimap = { minimapToggles += 1 }
        strip.sidebarButton.performClick(nil)
        strip.minimapButton.performClick(nil)
        strip.minimapButton.performClick(nil)
        #expect(sidebarToggles == 1)
        #expect(minimapToggles == 2)
    }

    @Test func accessoryButtonsReflectChromeState() {
        let strip = makeStrip()

        strip.updateAccessoryState(sidebarVisible: true, minimapOn: true)
        let onTint = strip.sidebarButton.contentTintColor
        #expect(strip.sidebarButton.accessibilityValue() as? String == "visible")
        #expect(strip.minimapButton.accessibilityValue() as? String == "visible")

        strip.updateAccessoryState(sidebarVisible: false, minimapOn: true)
        #expect(strip.sidebarButton.accessibilityValue() as? String == "hidden")
        #expect(strip.minimapButton.accessibilityValue() as? String == "visible")
        #expect(strip.sidebarButton.contentTintColor != onTint)
        #expect(strip.minimapButton.contentTintColor == onTint)

        // State survives a re-render (which recomputes tints for appearance).
        strip.render(tabs: tabs, current: 1, dark: false)
        #expect(strip.sidebarButton.accessibilityValue() as? String == "hidden")
    }

    @Test func accessoryButtonsBracketTheTabScroller() {
        let strip = makeStrip(width: 400)
        let scrollView = strip.subviews.compactMap { $0 as? NSScrollView }.first!
        #expect(strip.sidebarButton.frame.maxX <= scrollView.frame.minX)
        #expect(scrollView.frame.maxX <= strip.minimapButton.frame.minX)
        #expect(strip.sidebarButton.frame.minX < strip.minimapButton.frame.minX)
    }

    @Test func sameBufferOrderUpdatesViewsInPlace() {
        let strip = makeStrip()
        let before = strip.tabItems
        var updated = tabs
        updated[0].modified = true

        strip.render(tabs: updated, current: 1, dark: false)
        let after = strip.tabItems

        #expect(before.count == after.count)
        #expect(zip(before, after).allSatisfy { pair in pair.0 === pair.1 })
        #expect(after[0].isActive)
        #expect(after[0].label.stringValue.hasPrefix("●"))
    }
}

// MARK: - StatusBarView command segment

@Suite("StatusBarView command segment", .serialized)
@MainActor
struct StatusBarCommandSegmentTests {

    private let model = StatusModel(
        mode: .command, file: "docs/README.md", modified: false, branch: "main",
        line: 15, col: 9, totalLines: 310, project: "scopecreeplabs-site"
    )

    @MainActor
    private func chip(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let found = chip(identifier, in: subview) { return found }
        }
        return nil
    }

    @Test func renderCommandShowsCommandAndHidesChips() throws {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.render(model, dark: false)

        bar.renderCommand(NSAttributedString(string: ":wqa"))
        bar.layoutSubtreeIfNeeded()

        let strings = allStrings(in: bar)
        #expect(strings.contains(":wqa"))

        let fileChip = try #require(chip("status.file", in: bar))
        let branchChip = try #require(chip("status.branch", in: bar))
        let projectChip = try #require(chip("status.project", in: bar))
        let commandSegment = try #require(chip("status.command", in: bar))
        #expect(fileChip.isHidden)
        #expect(branchChip.isHidden)
        #expect(projectChip.isHidden)
        #expect(!commandSegment.isHidden)

        // Mode badge and line:col cap stay visible throughout.
        let modeBadge = try #require(chip("status.mode", in: bar))
        let lineCol = try #require(chip("status.lineCol", in: bar))
        #expect(!modeBadge.isHidden)
        #expect(!lineCol.isHidden)
        #expect(strings.contains("COMMAND"))
        #expect(strings.contains("15:9"))
    }

    @Test func renderCommandNilRestoresChips() throws {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.render(model, dark: false)
        bar.renderCommand(NSAttributedString(string: ":e file"))
        bar.renderCommand(nil)

        let fileChip = try #require(chip("status.file", in: bar))
        let branchChip = try #require(chip("status.branch", in: bar))
        let projectChip = try #require(chip("status.project", in: bar))
        let commandSegment = try #require(chip("status.command", in: bar))
        #expect(!fileChip.isHidden)
        #expect(!branchChip.isHidden)
        #expect(!projectChip.isHidden)
        #expect(commandSegment.isHidden)
        #expect(bar.activeCommand == nil)
        #expect(!allStrings(in: bar).contains(":e file"))
    }

    @Test func renderDuringActiveCommandKeepsChipsHidden() throws {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 24))
        bar.render(model, dark: false)
        bar.renderCommand(NSAttributedString(string: ":sort"))

        // A status update mid-command updates chip content but not visibility.
        var updated = model
        updated.file = "other/Name.swift"
        bar.render(updated, dark: false)

        let fileChip = try #require(chip("status.file", in: bar))
        #expect(fileChip.isHidden)
        #expect(allStrings(in: bar).contains(":sort"))

        // ...and the refreshed chips appear once the command ends.
        bar.renderCommand(nil)
        #expect(!fileChip.isHidden)
        #expect(allStrings(in: bar).contains("Name.swift"))
    }

    @Test func emptyBranchAndProjectStayHiddenAfterCommandEnds() throws {
        let bar = StatusBarView(frame: .zero)
        var bare = model
        bare.branch = ""
        bare.project = ""
        bar.render(bare, dark: false)
        bar.renderCommand(NSAttributedString(string: ":q"))
        bar.renderCommand(nil)

        let branchChip = try #require(chip("status.branch", in: bar))
        let projectChip = try #require(chip("status.project", in: bar))
        #expect(branchChip.isHidden)
        #expect(projectChip.isHidden)
    }
}
