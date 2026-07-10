// The ext_popupmenu completion popup: a borderless child panel hosting a
// virtualized NSTableView. 22pt rows: word (primary) + kind badge
// (right-aligned, secondary). The app converts the anchor grid cell into a
// window point; this controller takes the point.
import AppKit
import NvimKit

@MainActor
public final class PopupMenuPanelController: NSObject {
    public static let rowHeight: CGFloat = 22
    public static let maxVisibleRows = 10

    public let panel: NSPanel
    public let tableView: NSTableView
    public private(set) var isPresented = false
    private(set) var model: PopupMenuModel?

    private let scrollView: NSScrollView
    private let effectView: NSVisualEffectView
    private let font: NSFont
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("PopupMenuRow")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("item")

    public init(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.font = font

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 224),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 224))
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effectView

        tableView = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .regular

        scrollView = NSScrollView(frame: effectView.bounds.insetBy(dx: 0, dy: 4))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Legacy (always-visible-when-overflowing) scroller: the popup is
        // driven programmatically (nvim moves the selection), so an overlay
        // scroller never gets a gesture to appear for — the list looked
        // unscrollable whenever completions overflowed.
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        effectView.addSubview(scrollView)

        super.init()
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: Rendering (model -> view, one-way)

    /// Renders the model. Passing nil hides the popup. Selection-only updates
    /// (popupmenu_select) avoid a reload and just move + reveal the selection.
    public func render(_ model: PopupMenuModel?) {
        guard let model else {
            self.model = nil
            tableView.reloadData()
            dismiss()
            return
        }

        let itemsChanged = self.model?.items != model.items
        self.model = model
        if itemsChanged {
            tableView.reloadData()
        }

        if model.selected >= 0 && model.selected < model.items.count {
            tableView.selectRowIndexes(IndexSet(integer: model.selected), byExtendingSelection: false)
            tableView.scrollRowToVisible(model.selected)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: Presentation

    /// Presents the popup with its top-left at `point`, given in the window's
    /// contentView coordinate space (the app converts grid cell -> point).
    /// Safe headless: skips window-server work when `window` is not visible.
    /// Drop-down origin (screen coords, y-up): below the anchor when it
    /// fits above the window's bottom edge, otherwise FLIPPED to open
    /// upward from the anchor — a wildmenu anchored at the bottom status
    /// bar must never descend under the window/dock.
    static func panelOriginY(
        anchorScreenY: CGFloat, panelHeight: CGFloat, windowMinY: CGFloat
    ) -> CGFloat {
        let below = anchorScreenY - panelHeight
        return below >= windowMinY ? below : anchorScreenY
    }

    public func present(anchoredAt point: NSPoint, in window: NSWindow, model: PopupMenuModel) {
        render(model)
        guard let contentView = window.contentView else { return }

        let size = preferredSize(for: model)
        let windowPoint = contentView.convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let originY = Self.panelOriginY(
            anchorScreenY: screenPoint.y, panelHeight: size.height,
            windowMinY: window.frame.minY)
        panel.setFrame(
            NSRect(x: screenPoint.x, y: originY, width: size.width, height: size.height),
            display: false
        )
        effectView.frame = NSRect(origin: .zero, size: size)
        scrollView.frame = effectView.bounds.insetBy(dx: 0, dy: 4)

        if window.isVisible {
            if panel.parent !== window {
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        isPresented = true
    }

    public func dismiss() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isPresented = false
    }

    /// Width fits the longest word + kind badge (clamped); height shows up to
    /// `maxVisibleRows` rows.
    func preferredSize(for model: PopupMenuModel) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var maxWidth: CGFloat = 0
        for item in model.items {
            var width = (item.word as NSString).size(withAttributes: attrs).width
            if !item.kind.isEmpty {
                width += (item.kind as NSString).size(withAttributes: attrs).width + 16
            }
            maxWidth = max(maxWidth, width)
        }
        var width = min(max(maxWidth + 24, 160), 480)
        let rows = min(max(model.items.count, 1), Self.maxVisibleRows)
        if model.items.count > Self.maxVisibleRows {
            // Room for the legacy scroller so it never covers content.
            width = min(width + NSScroller.scrollerWidth(
                for: .regular, scrollerStyle: .legacy), 496)
        }
        let height = CGFloat(rows) * Self.rowHeight + 8
        return NSSize(width: width, height: height)
    }
}

// MARK: - Table plumbing

extension PopupMenuPanelController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model?.items.count ?? 0
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let items = model?.items, row >= 0, row < items.count else { return nil }
        let view =
            tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? PopupMenuRowView
            ?? PopupMenuRowView(font: font)
        view.identifier = Self.rowIdentifier
        view.configure(with: items[row])
        return view
    }
}

/// One 22pt completion row: word left in the editor's monospace face, kind
/// badge right-aligned in secondary color.
final class PopupMenuRowView: NSView {
    let wordField: NSTextField
    let kindField: NSTextField

    init(font: NSFont) {
        wordField = NSTextField(labelWithString: "")
        wordField.font = font
        wordField.textColor = .labelColor
        wordField.lineBreakMode = .byTruncatingTail

        kindField = NSTextField(labelWithString: "")
        kindField.font = NSFont.systemFont(ofSize: font.pointSize - 1)
        kindField.textColor = .secondaryLabelColor
        kindField.alignment = .right
        kindField.setContentHuggingPriority(.required, for: .horizontal)
        kindField.setContentCompressionResistancePriority(.required, for: .horizontal)

        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: PopupMenuPanelController.rowHeight))

        wordField.translatesAutoresizingMaskIntoConstraints = false
        kindField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordField)
        addSubview(kindField)
        NSLayoutConstraint.activate([
            wordField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            wordField.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kindField.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindField.leadingAnchor.constraint(
                greaterThanOrEqualTo: wordField.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with item: PopupMenuItem) {
        wordField.stringValue = item.word
        kindField.stringValue = item.kind
        kindField.isHidden = item.kind.isEmpty
    }
}
