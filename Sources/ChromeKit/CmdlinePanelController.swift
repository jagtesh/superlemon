// The ext_cmdline palette: a borderless floating panel, 560pt wide, anchored
// upper-center over the parent window (Spotlight-like). Vibrancy is allowed
// here because the cmdline is a transient palette surface (NORTHSTAR §1).
import AppKit

/// Renders `CmdlineModel` one-way (model -> view). Constructible and
/// render()-able headlessly; `present(over:)` is guarded on window presence.
@MainActor
public final class CmdlinePanelController {
    public static let panelWidth: CGFloat = 560
    /// Distance from the parent window's top edge to the panel's top edge.
    public static let topInset: CGFloat = 120

    public let panel: NSPanel
    public private(set) var isPresented = false

    let firstcLabel: NSTextField
    let contentLabel: NSTextField
    let blockLabel: NSTextField
    private let effectView: NSVisualEffectView
    /// The cmdline text font — kept in sync with the editor font by the app;
    /// applied on the next render.
    public var font: NSFont {
        didSet { firstcLabel.font = font }
    }
    private weak var parentWindow: NSWindow?

    public init(font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        self.font = font

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 44),
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

        effectView = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effectView

        blockLabel = NSTextField(labelWithAttributedString: NSAttributedString())
        blockLabel.maximumNumberOfLines = 0
        blockLabel.lineBreakMode = .byTruncatingMiddle
        blockLabel.preferredMaxLayoutWidth = Self.panelWidth - 32
        blockLabel.isHidden = true

        firstcLabel = NSTextField(labelWithString: "")
        firstcLabel.font = font
        firstcLabel.textColor = .secondaryLabelColor
        firstcLabel.setContentHuggingPriority(.required, for: .horizontal)
        firstcLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentLabel = NSTextField(labelWithAttributedString: NSAttributedString())
        contentLabel.maximumNumberOfLines = 1
        contentLabel.lineBreakMode = .byTruncatingHead
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let lineRow = NSStackView(views: [firstcLabel, contentLabel])
        lineRow.orientation = .horizontal
        lineRow.alignment = .firstBaseline
        lineRow.spacing = 6

        let column = NSStackView(views: [blockLabel, lineRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            column.topAnchor.constraint(equalTo: effectView.topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: effectView.bottomAnchor),
        ])
    }

    // MARK: Rendering (model -> view, one-way)

    /// Renders the model. Passing nil hides the panel. Safe headless.
    public func render(_ model: CmdlineModel?, resolver: HighlightResolver) {
        guard let model else {
            dismiss()
            return
        }

        firstcLabel.stringValue = model.prompt.isEmpty ? model.firstc : model.prompt
        firstcLabel.isHidden = firstcLabel.stringValue.isEmpty
        contentLabel.attributedStringValue = CmdlineRenderer.contentLine(
            for: model, font: font, resolver: resolver)

        if model.blockLines.isEmpty {
            blockLabel.isHidden = true
            blockLabel.attributedStringValue = NSAttributedString()
        } else {
            blockLabel.isHidden = false
            blockLabel.attributedStringValue = CmdlineRenderer.blockLines(
                model.blockLines, font: font, resolver: resolver)
        }

        layoutPanel()
    }

    // MARK: Presentation

    /// Attaches the panel above `window`, upper-center. No-ops without a
    /// content view; skips ordering when the window is not on screen (so
    /// headless tests never touch the window server).
    public func present(over window: NSWindow) {
        guard window.contentView != nil else { return }
        parentWindow = window
        layoutPanel()
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

    private func layoutPanel() {
        let contentHeight = max(44, effectView.fittingSize.height)
        var frame = NSRect(
            x: panel.frame.origin.x,
            y: panel.frame.origin.y,
            width: Self.panelWidth,
            height: contentHeight
        )
        if let parent = parentWindow {
            frame.origin.x = parent.frame.midX - Self.panelWidth / 2
            frame.origin.y = parent.frame.maxY - Self.topInset - contentHeight
        }
        panel.setFrame(frame, display: false)
        effectView.frame = panel.contentRect(forFrameRect: panel.frame)
            .offsetBy(dx: -panel.frame.origin.x, dy: -panel.frame.origin.y)
    }
}
