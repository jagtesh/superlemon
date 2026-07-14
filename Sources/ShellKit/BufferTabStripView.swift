// BufferTabStripView — Superlemon's tab strip band rendered as a native
// buffer tab strip (NORTHSTAR §4.1 item 2, §5 "Buffer strip", §8 geometry).
//
// 28 pt flat opaque band in the titlebar colors with a 1 px hairline
// bottom border. Tabs are leading-aligned, intrinsic width capped at
// ~220 pt, 13 pt basename labels (middle-truncated, full path as
// tooltip), a ● modified dot before the label, and an 11 pt ✕ close
// affordance. Fed by the runtime plugin's `superlemon.buffers` payload
// via `render(tabs:current:dark:)`. Overflowing tabs scroll horizontally
// (hidden scrollers, no elasticity) — the strip never wraps.

import AppKit

/// One buffer as shown in the tab strip — mirrors one entry of the
/// `superlemon.buffers` RPC payload (runtime/CONTRACT.md).
public struct BufferTab: Equatable, Sendable {
    public var bufnr: Int
    public var name: String
    public var modified: Bool
    /// VS Code/Sublime preview tab: rendered italic; promoted (pinned) by
    /// double-clicking the tab or the file in the sidebar.
    public var preview: Bool

    public init(bufnr: Int, name: String, modified: Bool = false, preview: Bool = false) {
        self.bufnr = bufnr
        self.name = name
        self.modified = modified
        self.preview = preview
    }
}

@MainActor
public final class BufferTabStripView: NSView {

    public static let stripHeight: CGFloat = 28

    /// Fired with the tab's `bufnr` when it is clicked.
    public var onSelect: ((Int) -> Void)?
    /// Fired with the tab's `bufnr` when its ✕ is clicked.
    public var onClose: ((Int) -> Void)?
    /// Fired with the tab's `bufnr` on double-click: promote a preview tab
    /// to permanent (no-op for tabs that are already permanent).
    public var onPromote: ((Int) -> Void)?
    /// Leading accessory button — toggle the file sidebar. The strip only
    /// fires the request; visibility state arrives back through
    /// `updateAccessoryState` (nvim owns the truth).
    public var onToggleSidebar: (() -> Void)?
    /// Trailing accessory button — toggle the minimap (same round-trip).
    public var onToggleMinimap: (() -> Void)?

    public private(set) var tabs: [BufferTab] = []
    public private(set) var current: Int = -1

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let bottomBorder = NSView()
    let sidebarButton = NSButton(title: "", target: nil, action: nil)
    let minimapButton = NSButton(title: "", target: nil, action: nil)
    private var sidebarVisible = true
    private var minimapOn = true
    private var isDark = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Collapses to height 0 when native tabs are off — clip so the tab
        // buttons never draw outside the strip's bounds.
        clipsToBounds = true
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        setUp()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.stripHeight)
    }

    /// The live tab item views, in tab order (test hook).
    var tabItems: [BufferTabItemView] {
        stack.arrangedSubviews.compactMap { $0 as? BufferTabItemView }
    }

    private func setUp() {
        wantsLayer = true
        setAccessibilityIdentifier("tabstrip")
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open buffers")

        bottomBorder.wantsLayer = true
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)

        // Horizontal-only overflow: hidden scrollers, no elasticity, never wraps.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        configureAccessoryButton(
            sidebarButton,
            symbolName: "sidebar.left",
            identifier: "tabstrip.toggleSidebar",
            label: "Toggle Sidebar",
            action: #selector(sidebarButtonClicked))
        configureAccessoryButton(
            minimapButton,
            symbolName: "map",
            identifier: "tabstrip.toggleMinimap",
            label: "Toggle Minimap",
            action: #selector(minimapButtonClicked))

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sidebarButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 24),
            minimapButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            minimapButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            minimapButton.widthAnchor.constraint(equalToConstant: 24),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(
                equalTo: sidebarButton.trailingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(
                equalTo: minimapButton.leadingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomBorder.topAnchor),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: clip.heightAnchor),
            heightAnchor.constraint(equalToConstant: Self.stripHeight),
        ])

        render(tabs: [], current: -1, dark: false)
    }

    private func configureAccessoryButton(
        _ button: NSButton, symbolName: String, identifier: String,
        label: String, action: Selector
    ) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        addSubview(button)
    }

    @objc private func sidebarButtonClicked() {
        onToggleSidebar?()
    }

    @objc private func minimapButtonClicked() {
        onToggleMinimap?()
    }

    /// Reflects the nvim-owned chrome state (`superlemon.chrome`) on the
    /// accessory buttons: enabled parts tint like active tab text, disabled
    /// ones like secondary text.
    public func updateAccessoryState(sidebarVisible: Bool, minimapOn: Bool) {
        self.sidebarVisible = sidebarVisible
        self.minimapOn = minimapOn
        refreshAccessoryButtons()
    }

    private func refreshAccessoryButtons() {
        sidebarButton.contentTintColor = sidebarVisible
            ? ShellPalette.tabActiveText(dark: isDark)
            : ShellPalette.secondaryText(dark: isDark)
        minimapButton.contentTintColor = minimapOn
            ? ShellPalette.tabActiveText(dark: isDark)
            : ShellPalette.secondaryText(dark: isDark)
        sidebarButton.setAccessibilityValue(sidebarVisible ? "visible" : "hidden")
        minimapButton.setAccessibilityValue(minimapOn ? "visible" : "hidden")
    }

    /// Re-renders the whole strip from the model. Idempotent; call on every
    /// `superlemon.buffers` notification and on appearance changes.
    public func render(tabs: [BufferTab], current: Int, dark: Bool) {
        let previousCurrent = self.current
        let previousIDs = self.tabs.map(\.bufnr)
        self.tabs = tabs
        self.current = current
        self.isDark = dark

        layer?.backgroundColor = ShellPalette.titlebarBackground(dark: dark).cgColor
        bottomBorder.layer?.backgroundColor = ShellPalette.hairline(dark: dark).cgColor
        refreshAccessoryButtons()

        let existing = tabItems
        if existing.map(\.bufnr) == tabs.map(\.bufnr) {
            // Buffer notifications are frequent. Preserve the view hierarchy
            // and scroll position when only active/modified/preview state
            // changed instead of rebuilding every tab.
            for (item, tab) in zip(existing, tabs) {
                item.configure(tab: tab, active: tab.bufnr == current, dark: dark)
            }
        } else {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for tab in tabs {
                let item = BufferTabItemView(tab: tab, active: tab.bufnr == current, dark: dark)
                item.onSelect = { [weak self] bufnr in self?.onSelect?(bufnr) }
                item.onClose = { [weak self] bufnr in self?.onClose?(bufnr) }
                item.onPromote = { [weak self] bufnr in self?.onPromote?(bufnr) }
                stack.addArrangedSubview(item)
                item.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
            }
        }

        if previousCurrent != current || previousIDs != tabs.map(\.bufnr) {
            layoutSubtreeIfNeeded()
            ensureCurrentTabVisible()
            // Auto Layout may not settle the stack's final width until the
            // enclosing window's layout pass; repeat once without animation.
            DispatchQueue.main.async { [weak self] in
                self?.ensureCurrentTabVisible()
            }
        }
    }

    /// Scrolls the active buffer into the hidden-scroller viewport.
    func ensureCurrentTabVisible() {
        guard let active = tabItems.first(where: \.isActive) else { return }
        _ = active.scrollToVisible(active.bounds)
    }

    /// Recolors for the given appearance (same signature family as the
    /// other ShellKit components).
    public func applyAppearance(dark: Bool) {
        render(tabs: tabs, current: current, dark: dark)
    }
}

// MARK: - Tab item

/// One tab: flat fill (active only), ● dot before a middle-truncated 13 pt
/// basename label, 11 pt ✕ close affordance. Clicking the body selects;
/// clicking ✕ closes.
@MainActor
final class BufferTabItemView: NSView {

    let bufnr: Int
    private(set) var isActive: Bool

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPromote: ((Int) -> Void)?

    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "", target: nil, action: nil)

    init(tab: BufferTab, active: Bool, dark: Bool) {
        self.bufnr = tab.bufnr
        self.isActive = active
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("tab.\(tab.bufnr)")
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        addSubview(label)

        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.setAccessibilityIdentifier("tab.close.\(tab.bufnr)")
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        configure(tab: tab, active: active, dark: dark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(tab: BufferTab, active: Bool, dark: Bool) {
        precondition(tab.bufnr == bufnr)
        isActive = active
        toolTip = tab.name.isEmpty ? nil : tab.name

        let basename = tab.name.isEmpty
            ? "[No Name]" : (tab.name as NSString).lastPathComponent
        label.stringValue = tab.modified ? "● \(basename)" : basename
        let accessibilityName = tab.modified ? "\(basename), modified" : basename
        setAccessibilityLabel(accessibilityName)
        setAccessibilitySelected(active)
        setAccessibilityHelp(active ? "Current buffer" : "Switches to this buffer")
        closeButton.setAccessibilityLabel("Close \(basename)")
        setAccessibilityCustomActions(tab.preview ? [
            NSAccessibilityCustomAction(name: "Keep Open") { [weak self] in
                guard let self else { return false }
                self.performPromote()
                return true
            }
        ] : [])
        let base = NSFont.systemFont(ofSize: 13)
        label.font = tab.preview
            ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            : base
        label.textColor = active
            ? ShellPalette.tabActiveText(dark: dark)
            : ShellPalette.tabInactiveText(dark: dark)
        closeButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ShellPalette.secondaryText(dark: dark),
            ])
        layer?.backgroundColor = active
            ? ShellPalette.tabActiveBackground(dark: dark).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            performPromote()
        } else {
            performSelect()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        performSelect()
        return true
    }

    /// Programmatic stand-in for a double-click (also the test hook).
    func performPromote() {
        onPromote?(bufnr)
    }

    /// Programmatic stand-in for a body click (also the test hook).
    func performSelect() {
        onSelect?(bufnr)
    }

    @objc private func closeClicked() {
        onClose?(bufnr)
    }
}
