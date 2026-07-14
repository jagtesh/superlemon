// ext_messages as a SINGLE replacing toast, top-right of the parent
// window's content view — new messages replace the current toast instead of
// stacking (stacks of stale toasts were noise). Everything shown is also
// appended to a timestamped history log; clicking the toast (or View ▸
// Message History) opens a scrollable, timestamped viewer so missed
// messages are never lost.
//
// Confirm-kind messages are never toasted — the app reads
// `ChromeState.pendingConfirm` and routes those to NSAlert.
import AppKit

/// superlemon.ui `toast show` kinds (runtime/CONTRACT.md). Mapped onto the
/// nvim message-kind styling: `error` gets red treatment; all kinds use the
/// controller's standard auto-dismiss interval.
public enum ToastKind: String, Sendable {
    case info
    case warn
    case error
}

/// One remembered message (the history log).
public struct ToastLogEntry: Sendable {
    public let date: Date
    public let kind: String  // nvim message kind ("emsg", "echo", …)
    public let isError: Bool
    public let text: String
}

@MainActor
public final class MessageToastController {
    public static let toastWidth: CGFloat = 320
    static let margin: CGFloat = 12
    static let historyCap = 200

    /// Every toast fades away after this many seconds — nothing nags; the
    /// history log (click a toast / View ▸ Message History) is the durable
    /// record. Overridable so tests don't wait real seconds.
    public var autoDismissInterval: TimeInterval = 3.0
    /// Fade-out duration; 0 removes immediately (tests, reduced motion).
    public var fadeDuration: TimeInterval = 0.25

    /// 0 or 1 — a single replacing toast (or tracked headlessly).
    public var activeToastCount: Int { currentToast == nil ? 0 : 1 }

    /// Timestamped log of everything shown, newest last, capped.
    public private(set) var history: [ToastLogEntry] = []

    private var currentToast: ToastView?
    private var currentID: UUID?
    private var currentIsAdHoc = false
    private var dismissTask: Task<Void, Never>?
    /// Message ids already logged/shown once — a later render of the same
    /// model list must not resurrect or re-log them.
    private var seenIDs: Set<UUID> = []
    private weak var container: NSView?
    private var historyPanel: NSPanel?
    private var historyTextView: NSTextView?

    public init() {}

    deinit {
        dismissTask?.cancel()
    }

    // MARK: Attachment

    /// Convenience: attach to a window's content view.
    public func attach(to window: NSWindow) {
        if let contentView = window.contentView { attach(to: contentView) }
    }

    /// The toast becomes a subview of `view`, pinned to its top-right corner.
    public func attach(to view: NSView) {
        guard container !== view else { return }
        if let toast = currentToast {
            toast.removeFromSuperview()
            view.addSubview(toast)
        }
        container = view
        layoutToast()
    }

    // MARK: Rendering (model -> view, one-way)

    /// Syncs with the message list from ChromeState: logs anything new and
    /// shows the NEWEST non-confirm message as the single toast. Safe
    /// headless (bookkeeping only without a container).
    public func render(_ messages: [MessageModel]) {
        let fresh = messages.filter { !$0.needsPrompt && !seenIDs.contains($0.id) }
        for message in fresh {
            log(kind: message.kind, isError: message.isError, text: message.text)
            seenIDs.insert(message.id)
        }
        if let newest = fresh.last {
            show(message: newest, adHoc: false)
        } else if currentID != nil, !currentIsAdHoc,
            !messages.contains(where: { $0.id == currentID })
        {
            removeCurrentToast()  // msg_clear / replace_last removed it
        }
    }

    /// superlemon.ui `toast show` (runtime/CONTRACT.md): same single-toast
    /// pipeline; replaces whatever is showing.
    public func showAdHoc(text: String, kind: ToastKind) {
        let nvimKind: String
        switch kind {
        case .info: nvimKind = "echo"
        case .warn: nvimKind = "wmsg"
        case .error: nvimKind = "emsg"
        }
        let message = MessageModel(kind: nvimKind, content: [Chunk(hlID: 0, text: text)])
        log(kind: nvimKind, isError: kind == .error, text: text)
        seenIDs.insert(message.id)
        show(message: message, adHoc: true)
    }

    /// Dismiss the current toast if it matches (kept for API compatibility;
    /// auto-dismiss and clicks route here).
    public func dismissToast(_ id: UUID) {
        guard currentID == id else { return }
        removeCurrentToast()
    }

    /// Test/diagnostic hook that observes the real auto-dismiss task without
    /// making callers guess at main-actor scheduling latency.
    func waitForPendingDismissal() async {
        await dismissTask?.value
    }

    // MARK: History

    /// Opens (or refreshes) the timestamped message-history panel.
    public func showHistory() {
        let panel = historyPanel ?? makeHistoryPanel()
        refreshHistoryText()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Internals

    private func show(message: MessageModel, adHoc: Bool) {
        removeCurrentToast()
        let toast = ToastView(message: message, width: Self.toastWidth)
        toast.onClick = { [weak self] in
            // The toast doubles as the entry point to the log: click opens
            // history (and clears the toast).
            self?.dismissToast(message.id)
            self?.showHistory()
        }
        currentToast = toast
        currentID = message.id
        currentIsAdHoc = adHoc
        container?.addSubview(toast)
        layoutToast()
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message.text,
                .priority: message.isError
                    ? NSAccessibilityPriorityLevel.high.rawValue
                    : NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        let id = message.id
        dismissTask = Task { [weak self] in
            let interval = self?.autoDismissInterval ?? 3.0
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissToast(id)
        }
    }

    private func removeCurrentToast() {
        dismissTask?.cancel()
        dismissTask = nil
        let toast = currentToast
        currentToast = nil
        currentID = nil
        currentIsAdHoc = false
        guard let toast else { return }
        if fadeDuration <= 0 {
            toast.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration
            toast.animator().alphaValue = 0
        }) {
            Task { @MainActor in
                toast.removeFromSuperview()
            }
        }
    }

    private func layoutToast() {
        guard let container, let toast = currentToast else { return }
        toast.frame.origin = NSPoint(
            x: container.bounds.maxX - Self.toastWidth - Self.margin,
            y: container.bounds.maxY - Self.margin - toast.frame.height)
        toast.autoresizingMask = [.minXMargin, .minYMargin]
    }

    private func log(kind: String, isError: Bool, text: String) {
        history.append(ToastLogEntry(date: Date(), kind: kind, isError: isError, text: text))
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        if historyPanel?.isVisible == true {
            refreshHistoryText()
        }
    }

    private func makeHistoryPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Message History"
        panel.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = text
        panel.contentView?.addSubview(scroll)

        historyPanel = panel
        historyTextView = text
        return panel
    }

    private func refreshHistoryText() {
        guard let text = historyTextView else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        for entry in history.reversed() {  // newest first
            let stamp = NSAttributedString(
                string: "[\(formatter.string(from: entry.date))] ",
                attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
            let kind = NSAttributedString(
                string: entry.kind.padding(toLength: 10, withPad: " ", startingAt: 0),
                attributes: [
                    .font: mono,
                    .foregroundColor: entry.isError
                        ? NSColor.systemRed : NSColor.tertiaryLabelColor,
                ])
            let body = NSAttributedString(
                string: entry.text + "\n",
                attributes: [
                    .font: mono,
                    .foregroundColor: entry.isError ? NSColor.systemRed : NSColor.labelColor,
                ])
            result.append(stamp)
            result.append(kind)
            result.append(body)
        }
        text.textStorage?.setAttributedString(result)
        text.scrollToBeginningOfDocument(nil)
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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(message.isError ? "Error message" : "Message")
        setAccessibilityValue(message.text)
        setAccessibilityHelp("Opens Message History")
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
