// QuickOpenPanelController — Superlemon's fuzzy file palette
// (NORTHSTAR §4.3, §5 "Quick Open / palettes", DESIGN §14.4).
//
// Borderless key NSPanel, 498×346 pt at its design size (clamped for small
// windows/screens), upper-center over the parent (top edge ≈96 pt below the
// content top), 10 pt radius, #ECECEC
// chrome. Search row 34 pt (white field surface, live right-aligned count),
// results in an NSTableView with 44 pt two-line rows (filename 13 pt /
// relative dir 11 pt gray, matched characters bolded from scorer
// positions). ↑/↓ move selection, ⏎ opens, ⎋ closes. While presented a
// 30% black scrim covers the parent window's content.
//
// The controller is UI-only: the embedder feeds results (typically from
// FileIndex) via `display(results:totalCount:)` and reacts to
// `onQueryChange` / `onOpen` / `onClose`. Constructible and renderable
// headless (no window/screen required) for tests.

import AppKit

public struct QuickOpenResult: Equatable, Sendable {
    /// Relative path, e.g. "src/pages/index.astro" — or, for superlemon.ui
    /// palette sessions, the plugin-provided row title.
    public let path: String
    /// Matched character indices into `path` (from FuzzyScorer) for bolding.
    public let positions: [Int]
    /// Additive (superlemon.ui palette): explicit second line. nil keeps
    /// the classic rendering that derives basename + directory from `path`;
    /// non-nil renders `path` whole as the primary line and this as the
    /// secondary line (empty string hides the secondary line).
    public let subtitle: String?

    public init(path: String, positions: [Int] = []) {
        self.init(path: path, subtitle: nil, positions: positions)
    }

    public init(path: String, subtitle: String?, positions: [Int] = []) {
        self.path = path
        self.subtitle = subtitle
        self.positions = positions
    }
}

@MainActor
public final class QuickOpenPanelController: NSObject {

    // Geometry (NORTHSTAR §8)
    public static let panelSize = NSSize(width: 498, height: 346)
    public static let searchRowHeight: CGFloat = 34
    public static let resultRowHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 10
    static let topOffset: CGFloat = 96
    static let scrimAlpha: CGFloat = 0.30

    // Callbacks
    public var onOpen: ((String) -> Void)?
    public var onClose: (() -> Void)?
    /// Fired after a short trailing-edge debounce; embedder queries the index
    /// and calls `display(results:totalCount:)`.
    public var onQueryChange: ((String) -> Void)?
    /// Additive (superlemon.ui palette): fired with the selected row INDEX
    /// (into the last `display` results) when a row is opened, BEFORE the
    /// panel closes — sessions that key rows by opaque ids resolve them
    /// here. `onOpen` still fires with the path afterwards.
    public var onOpenIndex: ((Int) -> Void)?

    /// Additive (superlemon.ui palette): the search field's placeholder.
    private var placeholderText = "Search files"
    public var placeholder: String {
        get { placeholderText }
        set {
            placeholderText = newValue
            applyAppearance(dark: isDark)  // restyle for legibility
        }
    }

    // UI
    public let panel: NSPanel
    let searchField = NSTextField()
    let countLabel = NSTextField(labelWithString: "")
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchRow = NSView()
    private let magnifierLabel = NSTextField(labelWithString: "🔍")
    private var scrimView: NSView?
    private weak var parentWindow: NSWindow?
    /// True from present() until close(); results arriving after close are
    /// ignored rather than silently reviving a stale palette session.
    public private(set) var sessionActive = false
    /// Changes for every open and close boundary. Async result producers can
    /// pass a captured value to `display` for stale-result protection.
    public private(set) var presentationGeneration: UInt64 = 0
    private let queryDebounce: Duration
    private var queryDebounceTask: Task<Void, Never>?

    private(set) var results: [QuickOpenResult] = []
    private var isDark = false

    public var isPresented: Bool { panel.isVisible }
    public var query: String { searchField.stringValue }
    public var selectedIndex: Int { tableView.selectedRow }
    public var selectedPath: String? {
        let row = tableView.selectedRow
        guard row >= 0 && row < results.count else { return nil }
        return results[row].path
    }

    public init(queryDebounce: Duration = .milliseconds(50)) {
        self.queryDebounce = queryDebounce
        panel = KeyableQuickOpenPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        buildUI()
    }

    // MARK: - UI construction

    private func buildUI() {
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false

        let content = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.masksToBounds = true
        panel.contentView = content

        // Search row (top)
        searchRow.wantsLayer = true
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchRow)

        magnifierLabel.font = .systemFont(ofSize: 12)
        magnifierLabel.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(magnifierLabel)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.placeholderString = "Search files"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("quickopen.query")
        searchRow.addSubview(searchField)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setAccessibilityIdentifier("quickopen.count")
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchRow.addSubview(countLabel)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.setAccessibilityIdentifier("quickopen.hairline")
        searchRow.addSubview(hairline)

        // Results table
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.resultRowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.setAccessibilityIdentifier("quickopen.results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchRow.topAnchor.constraint(equalTo: content.topAnchor),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),

            magnifierLabel.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 10),
            magnifierLabel.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: magnifierLabel.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),

            hairline.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        applyAppearance(dark: false)
    }

    public func applyAppearance(dark: Bool) {
        isDark = dark
        panel.contentView?.layer?.backgroundColor = ShellPalette.paletteBackground(dark: dark).cgColor
        searchRow.layer?.backgroundColor = ShellPalette.paletteField(dark: dark).cgColor
        searchField.textColor = ShellPalette.primaryText(dark: dark)
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholderText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: ShellPalette.paletteTertiary(dark: dark),
            ])
        countLabel.textColor = ShellPalette.paletteTertiary(dark: dark)
        magnifierLabel.textColor = ShellPalette.paletteTertiary(dark: dark)
        if let hairline = searchRow.subviews.first(where: {
            $0.accessibilityIdentifier() == "quickopen.hairline"
        }) {
            hairline.layer?.backgroundColor = ShellPalette.hairline(dark: dark).cgColor
        }
        tableView.reloadData()
    }

    // MARK: - Presentation

    /// Presents the palette over `parent`, installing the 30% black scrim
    /// over the parent's content view. Passing nil shows the panel
    /// standalone (headless/tests).
    public func present(over parent: NSWindow?) {
        // Re-presenting while open must never stack a second scrim/child
        // window (the ⌘P-piles-up bug): just refocus the existing session.
        if sessionActive {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
            return
        }
        scrimView?.removeFromSuperview()  // belt & braces against stale scrims
        scrimView = nil

        parentWindow = parent
        sessionActive = true
        presentationGeneration &+= 1
        queryDebounceTask?.cancel()
        queryDebounceTask = nil
        searchField.stringValue = ""
        if let parent {
            let dark =
                parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            applyAppearance(dark: dark)
        }
        onQueryChange?("")

        if let parent, let parentContent = parent.contentView {
            // Scrim over the full content region while the palette is active.
            let scrim = ScrimView(frame: parentContent.bounds)
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.scrimAlpha).cgColor
            scrim.autoresizingMask = [.width, .height]
            scrim.setAccessibilityIdentifier("quickopen.scrim")
            scrim.onClick = { [weak self] in self?.close() }
            parentContent.addSubview(scrim, positioned: .above, relativeTo: nil)
            scrimView = scrim

            positionPanel(over: parent)
            startObservingGeometry(of: parent)
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.setContentSize(Self.panelSize)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    public func close() {
        guard sessionActive || isPresented || scrimView != nil else { return }
        sessionActive = false
        presentationGeneration &+= 1
        queryDebounceTask?.cancel()
        queryDebounceTask = nil
        scrimView?.removeFromSuperview()
        scrimView = nil
        stopObservingParentGeometry()
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
        onClose?()
    }

    private func positionPanel(over parent: NSWindow) {
        guard let parentContent = parent.contentView else { return }
        let contentFrameOnScreen = parent.convertToScreen(
            parentContent.convert(parentContent.bounds, to: nil)
        )
        var available = contentFrameOnScreen
        if let visibleFrame = parent.screen?.visibleFrame {
            let intersection = available.intersection(visibleFrame)
            if !intersection.isNull, !intersection.isEmpty { available = intersection }
        }
        available = available.insetBy(dx: min(12, available.width / 4),
                                      dy: min(12, available.height / 4))

        let size = NSSize(
            width: min(Self.panelSize.width, max(1, available.width)),
            height: min(Self.panelSize.height, max(1, available.height)))
        let desiredX = contentFrameOnScreen.midX - size.width / 2
        let desiredY = contentFrameOnScreen.maxY - Self.topOffset - size.height
        let x = min(max(desiredX, available.minX), max(available.minX, available.maxX - size.width))
        let y = min(max(desiredY, available.minY), max(available.minY, available.maxY - size.height))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
    }

    private func startObservingGeometry(of parent: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(parentGeometryChanged(_:)),
            name: NSWindow.didResizeNotification, object: parent)
        center.addObserver(
            self, selector: #selector(parentGeometryChanged(_:)),
            name: NSWindow.didMoveNotification, object: parent)
        center.addObserver(
            self, selector: #selector(parentGeometryChanged(_:)),
            name: NSWindow.didChangeScreenNotification, object: parent)
    }

    private func stopObservingParentGeometry() {
        guard let parentWindow else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResizeNotification, object: parentWindow)
        center.removeObserver(self, name: NSWindow.didMoveNotification, object: parentWindow)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: parentWindow)
    }

    @objc private func parentGeometryChanged(_ notification: Notification) {
        guard sessionActive, let parentWindow else { return }
        positionPanel(over: parentWindow)
    }

    // MARK: - Data

    /// Feed results (typically from `FileIndex.query`). `totalCount` drives
    /// the live "32 files" label; pass the index's full file count.
    @discardableResult
    public func display(
        results: [QuickOpenResult], totalCount: Int, isTruncated: Bool = false,
        matchingCount: Int? = nil,
        presentationGeneration expectedGeneration: UInt64? = nil
    ) -> Bool {
        guard sessionActive else { return false }
        if let expectedGeneration, expectedGeneration != presentationGeneration { return false }
        self.results = results
        if let matchingCount {
            let noun = matchingCount == 1 ? "match" : "matches"
            let count = Self.formattedCount(matchingCount)
            countLabel.stringValue = isTruncated
                ? "\(count) \(noun) (partial)"
                : "\(count) \(noun)"
            if matchingCount > results.count || isTruncated {
                let shown = min(results.count, matchingCount)
                countLabel.toolTip = isTruncated
                    ? "Showing the top \(shown) matches from a truncated \(totalCount)-file index."
                    : "Showing the top \(shown) of \(matchingCount) matches."
            } else {
                countLabel.toolTip = nil
            }
        } else if isTruncated {
            countLabel.stringValue = "\(Self.formattedCount(totalCount))+ indexed"
            countLabel.toolTip = "Quick Open indexed the first \(totalCount) files; results may be incomplete."
        } else {
            countLabel.stringValue = totalCount == 1
                ? "1 file" : "\(Self.formattedCount(totalCount)) files"
            countLabel.toolTip = nil
        }
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else {
            tableView.deselectAll(nil)
        }
        return true
    }

    private static func formattedCount(_ value: Int) -> String {
        let digits = String(max(0, value))
        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3)
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) {
                result.append(",")
            }
            result.append(character)
        }
        return result
    }

    // MARK: - Selection / keys

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        let next = min(max(current + delta, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc func openSelection() {
        guard let path = selectedPath else { return }
        let row = tableView.selectedRow
        onOpenIndex?(row)
        onOpen?(path)
        close()
    }

    private func scheduleQueryChange(_ query: String) {
        queryDebounceTask?.cancel()
        let generation = presentationGeneration
        queryDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.queryDebounce ?? .zero)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.sessionActive,
                self.presentationGeneration == generation,
                self.searchField.stringValue == query
            else { return }
            self.queryDebounceTask = nil
            self.onQueryChange?(query)
        }
    }

    /// Test/diagnostic hook for the currently scheduled trailing-edge query.
    func waitForPendingQueryChange() async {
        await queryDebounceTask?.value
    }
}

// MARK: - Search field delegate (keys)

extension QuickOpenPanelController: NSTextFieldDelegate {

    public func controlTextDidChange(_ obj: Notification) {
        scheduleQueryChange(searchField.stringValue)
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - Table data source / delegate

extension QuickOpenPanelController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("QuickOpenCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
            as? QuickOpenCellView ?? QuickOpenCellView(identifier: identifier)
        cell.configure(result: results[row], dark: isDark)
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        QuickOpenRowView(dark: isDark)
    }
}

// MARK: - Row (selection fill)

@MainActor
final class QuickOpenRowView: NSTableRowView {
    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        // Full-width square-edged fill (#DBDBDB light / #343434 dark).
        ShellPalette.paletteSelection(dark: dark).setFill()
        bounds.fill()
    }
}

// MARK: - Two-line cell

@MainActor
final class QuickOpenCellView: NSView {
    private let iconLabel = NSTextField(labelWithString: "📄")
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconLabel.font = .systemFont(ofSize: 16)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setAccessibilityIdentifier("quickopen.cell.title")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setAccessibilityIdentifier("quickopen.cell.path")

        for view in [iconLabel, titleLabel, pathLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(result: QuickOpenResult, dark: Bool) {
        if let subtitle = result.subtitle {
            // superlemon.ui palette row: the title renders whole as the
            // primary line (positions index into it), subtitle below.
            titleLabel.attributedStringValue = Self.emphasized(
                result.path, positions: result.positions, size: 13,
                color: ShellPalette.primaryText(dark: dark)
            )
            pathLabel.attributedStringValue = Self.emphasized(
                subtitle, positions: [], size: 11,
                color: ShellPalette.paletteSecondary(dark: dark)
            )
            pathLabel.isHidden = subtitle.isEmpty
            return
        }
        let path = result.path
        let chars = Array(path)
        let slashIndex = chars.lastIndex(of: "/")
        let nameStart = slashIndex.map { $0 + 1 } ?? 0
        let name = String(chars[nameStart...])
        let dir = nameStart > 0 ? String(chars[..<(nameStart - 1)]) : ""

        // Split scorer positions between the two lines and bold them.
        let namePositions = result.positions.filter { $0 >= nameStart }.map { $0 - nameStart }
        let dirPositions = result.positions.filter { $0 < nameStart - 1 }

        titleLabel.attributedStringValue = Self.emphasized(
            name, positions: namePositions, size: 13,
            color: ShellPalette.primaryText(dark: dark)
        )
        pathLabel.attributedStringValue = Self.emphasized(
            dir, positions: dirPositions, size: 11,
            color: ShellPalette.paletteSecondary(dark: dark)
        )
        pathLabel.isHidden = dir.isEmpty
    }

    static func emphasized(
        _ text: String, positions: [Int], size: CGFloat, color: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]
        )
        let bold = NSFont.boldSystemFont(ofSize: size)
        // positions are character offsets; map to utf16 ranges.
        let chars = Array(text)
        for p in positions where p < chars.count {
            let start = String(chars[..<p]).utf16.count
            let length = String(chars[p]).utf16.count
            result.addAttribute(.font, value: bold, range: NSRange(location: start, length: length))
        }
        return result
    }
}

/// The dimming layer behind the palette: clicking it dismisses (standard
/// macOS modal-scrim behavior).
@MainActor
final class ScrimView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}


/// Borderless windows/panels return false from canBecomeKey by default —
/// which silently sent every palette keystroke to the main window (i.e.
/// into the nvim buffer). The palette must own the keyboard while open.
@MainActor
final class KeyableQuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
