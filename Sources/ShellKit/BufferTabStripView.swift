// buffer tab strip (NORTHSTAR §4.1 item 2, §5 "Tab strip", §8 geometry).
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

    public init(bufnr: Int, name: String, modified: Bool = false) {
        self.bufnr = bufnr
        self.name = name
        self.modified = modified
    }
}

@MainActor
public final class BufferTabStripView: NSView {

    public static let stripHeight: CGFloat = 28

    /// Fired with the tab's `bufnr` when it is clicked.
    public var onSelect: ((Int) -> Void)?
    /// Fired with the tab's `bufnr` when its ✕ is clicked.
    public var onClose: ((Int) -> Void)?

    public private(set) var tabs: [BufferTab] = []
    public private(set) var current: Int = -1

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let bottomBorder = NSView()
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

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
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

    /// Re-renders the whole strip from the model. Idempotent; call on every
    /// `superlemon.buffers` notification and on appearance changes.
    public func render(tabs: [BufferTab], current: Int, dark: Bool) {
        self.tabs = tabs
        self.current = current
        self.isDark = dark

        layer?.backgroundColor = ShellPalette.titlebarBackground(dark: dark).cgColor
        bottomBorder.layer?.backgroundColor = ShellPalette.hairline(dark: dark).cgColor

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tab in tabs {
            let item = BufferTabItemView(tab: tab, active: tab.bufnr == current, dark: dark)
            item.onSelect = { [weak self] bufnr in self?.onSelect?(bufnr) }
            item.onClose = { [weak self] bufnr in self?.onClose?(bufnr) }
            stack.addArrangedSubview(item)
            item.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
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

    let label = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "", target: nil, action: nil)

    init(tab: BufferTab, active: Bool, dark: Bool) {
        self.bufnr = tab.bufnr
        self.isActive = active
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("tab.\(tab.bufnr)")
        toolTip = tab.name.isEmpty ? nil : tab.name

        let basename = tab.name.isEmpty
            ? "[No Name]" : (tab.name as NSString).lastPathComponent
        label.stringValue = tab.modified ? "● \(basename)" : basename
        label.font = .systemFont(ofSize: 13)
        label.textColor = active
            ? ShellPalette.tabActiveText(dark: dark)
            : ShellPalette.tabInactiveText(dark: dark)
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        addSubview(label)

        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ShellPalette.secondaryText(dark: dark),
            ]
        )
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.setAccessibilityIdentifier("tab.close.\(tab.bufnr)")
        addSubview(closeButton)

        layer?.backgroundColor = active
            ? ShellPalette.tabActiveBackground(dark: dark).cgColor
            : NSColor.clear.cgColor

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        performSelect()
    }

    /// Programmatic stand-in for a body click (also the test hook).
    func performSelect() {
        onSelect?(bufnr)
    }

    @objc private func closeClicked() {
        onClose?(bufnr)
    }
}
