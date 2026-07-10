// ext_messages as stacking transient toasts, top-right of the parent
// window's content view. Plain layer-backed NSViews, not panels (NORTHSTAR:
// flat opaque surfaces + hairlines; vibrancy only on palette-class panels).
//
// Confirm-kind messages are never toasted — the app reads
// `ChromeState.pendingConfirm` and routes those to NSAlert.
import AppKit

@MainActor
public final class MessageToastController {
    public static let toastWidth: CGFloat = 320
    static let margin: CGFloat = 12
    static let spacing: CGFloat = 8

    /// Non-error toasts dismiss after this many seconds. Overridable so tests
    /// don't wait 4 real seconds. Error toasts persist until clicked or
    /// cleared by `msg_clear`.
    public var autoDismissInterval: TimeInterval = 4.0

    /// Number of toast views currently shown (or tracked headlessly).
    public var activeToastCount: Int { toastViews.count }

    private(set) var toastViews: [UUID: ToastView] = [:]
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    /// User-dismissed messages: never resurrected by a later render of the
    /// same model list. Pruned to the live message set on each render.
    private var dismissedIDs: Set<UUID> = []
    private var order: [UUID] = []
    private weak var container: NSView?

    public init() {}

    deinit {
        for task in dismissTasks.values { task.cancel() }
    }

    // MARK: Attachment

    /// Convenience: attach to a window's content view.
    public func attach(to window: NSWindow) {
        if let contentView = window.contentView { attach(to: contentView) }
    }

    /// Toasts become subviews of `view`, stacked from its top-right corner.
    public func attach(to view: NSView) {
        guard container !== view else { return }
        // Move any live toasts to the new container.
        for id in order {
            toastViews[id]?.removeFromSuperview()
            if let toast = toastViews[id] { view.addSubview(toast) }
        }
        container = view
        layoutToasts()
    }

    // MARK: Rendering (model -> view, one-way)

    /// Syncs toast views with the message list from ChromeState. Confirm-kind
    /// (`needsPrompt`) messages are skipped. Safe headless: without an
    /// attached container this only does bookkeeping.
    public func render(_ messages: [MessageModel]) {
        dismissedIDs.formIntersection(Set(messages.map(\.id)))

        let visible = messages.filter { !$0.needsPrompt && !dismissedIDs.contains($0.id) }
        let visibleIDs = Set(visible.map(\.id))

        // Remove toasts whose message is gone (msg_clear, replace_last).
        for id in order where !visibleIDs.contains(id) {
            removeToast(id)
        }

        // Add toasts for new messages.
        for message in visible where toastViews[message.id] == nil {
            let toast = ToastView(message: message, width: Self.toastWidth)
            toast.onClick = { [weak self] in self?.dismissToast(message.id) }
            toastViews[message.id] = toast
            container?.addSubview(toast)
            if !message.isError {
                scheduleAutoDismiss(of: message.id)
            }
        }

        order = visible.map(\.id)
        layoutToasts()
    }

    /// Click-to-dismiss (also used by the auto-dismiss task). The message
    /// stays in ChromeState; it just won't be toasted again.
    public func dismissToast(_ id: UUID) {
        guard toastViews[id] != nil else { return }
        dismissedIDs.insert(id)
        removeToast(id)
        layoutToasts()
    }

    // MARK: Internals

    private func scheduleAutoDismiss(of id: UUID) {
        dismissTasks[id] = Task { [weak self] in
            let interval = self?.autoDismissInterval ?? 4.0
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissToast(id)
        }
    }

    private func removeToast(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        toastViews[id]?.removeFromSuperview()
        toastViews[id] = nil
        order.removeAll { $0 == id }
    }

    private func layoutToasts() {
        guard let container else { return }
        var top = container.bounds.maxY - Self.margin
        let x = container.bounds.maxX - Self.toastWidth - Self.margin
        for id in order {
            guard let toast = toastViews[id] else { continue }
            let height = toast.frame.height
            toast.frame.origin = NSPoint(x: x, y: top - height)
            toast.autoresizingMask = [.minXMargin, .minYMargin]
            top -= height + Self.spacing
        }
    }
}

/// One toast: flat opaque rounded rect, hairline border, message text.
/// Error kinds get a red-tinted background per NORTHSTAR light/dark.
final class ToastView: NSView {
    let message: MessageModel
    var onClick: (() -> Void)?
    private let label: NSTextField

    init(message: MessageModel, width: CGFloat) {
        self.message = message

        label = NSTextField(wrappingLabelWithString: message.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 8
        label.isSelectable = false

        let textWidth = width - 24
        label.preferredMaxLayoutWidth = textWidth
        let textHeight = min(
            label.sizeThatFits(NSSize(width: textWidth, height: 10_000)).height, 160)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: textHeight + 16))

        label.frame = NSRect(x: 12, y: 8, width: textWidth, height: textHeight)
        label.autoresizingMask = [.width]
        addSubview(label)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved during updateLayer so the toast tracks appearance changes.
        // NORTHSTAR: light surface #FFFFFF, dark chrome #1E1E1E; hairlines
        // #DADADB light / #000000 dark; errors tinted red per appearance.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background: NSColor
        let border: NSColor
        if message.isError {
            background = dark
                ? NSColor(srgbRed: 0.24, green: 0.11, blue: 0.11, alpha: 1)
                : NSColor(srgbRed: 0.99, green: 0.93, blue: 0.93, alpha: 1)
            border = NSColor.systemRed.withAlphaComponent(dark ? 0.55 : 0.35)
        } else {
            background = dark
                ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)  // #1E1E1E
                : NSColor.white
            border = dark
                ? NSColor.black
                : NSColor(srgbRed: 0.855, green: 0.855, blue: 0.859, alpha: 1)  // #DADADB
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
