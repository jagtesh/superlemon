// (NORTHSTAR §4.1 item 4, §5 "Status bar", DESIGN §14.5).
//
// 24 pt flat opaque bar with a hairline top border. Left: mode badge
// (color by mode, chip-flip per appearance), file chip (name + modified
// dot), branch chip (glyph + name; hidden when branch is empty). Right:
// line:col cap chip (green). Fed by the runtime plugin's
// `superlemon.status` payload via `render(_:dark:)`. The flexible middle
// doubles as a command-line overlay via `renderCommand(_:)`.

import AppKit

/// Editor mode as shown in the badge, derived from nvim's raw mode string.
public enum StatusMode: String, Equatable, Sendable {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case command = "COMMAND"
    case replace = "REPLACE"

    /// Maps `vim.api.nvim_get_mode().mode` (raw, e.g. "n", "niI", "i",
    /// "v", "V", CTRL-V, "c", "R") to a badge.
    public init(rawNvimMode: String) {
        switch rawNvimMode.first {
        case "i": self = .insert
        case "v", "V", "\u{16}", "s", "S": self = .visual
        case "c": self = .command
        case "R": self = .replace
        default: self = .normal
        }
    }
}

/// Everything the status bar renders — mirrors the `superlemon.status`
/// RPC payload (runtime/CONTRACT.md).
public struct StatusModel: Equatable, Sendable {
    public var mode: StatusMode
    public var file: String
    public var modified: Bool
    public var branch: String
    public var line: Int
    public var col: Int
    public var totalLines: Int
    public var project: String

    public init(
        mode: StatusMode = .normal,
        file: String = "",
        modified: Bool = false,
        branch: String = "",
        line: Int = 1,
        col: Int = 1,
        totalLines: Int = 1,
        project: String = ""
    ) {
        self.mode = mode
        self.file = file
        self.modified = modified
        self.branch = branch
        self.line = line
        self.col = col
        self.totalLines = totalLines
        self.project = project
    }
}

@MainActor
public final class StatusBarView: NSView {

    public static let barHeight: CGFloat = 24

    private let stack = NSStackView()
    private let modeBadge = ChipView()
    private let fileChip = ChipView()
    private let branchChip = ChipView()
    private let projectChip = ChipView()
    private let lineColChip = ChipView()
    private let topBorder = NSView()
    private let commandSegment = NSView()
    private let commandLabel = NSTextField(labelWithString: "")

    private var isDark = false
    public private(set) var model = StatusModel()
    /// Non-nil while the command-line overlay occupies the flexible middle
    /// of the bar (see `renderCommand(_:)`).
    public private(set) var activeCommand: NSAttributedString?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The bar collapses to height 0 when native chrome is off — without
        // clipping, AppKit happily draws the chips outside the bounds.
        clipsToBounds = true
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        setUp()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    private func setUp() {
        wantsLayer = true

        topBorder.wantsLayer = true
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        modeBadge.setAccessibilityIdentifier("status.mode")
        fileChip.setAccessibilityIdentifier("status.file")
        branchChip.setAccessibilityIdentifier("status.branch")
        projectChip.setAccessibilityIdentifier("status.project")
        lineColChip.setAccessibilityIdentifier("status.lineCol")

        // Command overlay segment: mono single-line, tail-truncated, hidden
        // until renderCommand(non-nil).
        commandSegment.setAccessibilityIdentifier("status.command")
        commandSegment.isHidden = true
        commandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.usesSingleLineMode = true
        commandLabel.maximumNumberOfLines = 1
        commandLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandSegment.addSubview(commandLabel)
        NSLayoutConstraint.activate([
            commandLabel.leadingAnchor.constraint(equalTo: commandSegment.leadingAnchor, constant: 8),
            commandLabel.trailingAnchor.constraint(lessThanOrEqualTo: commandSegment.trailingAnchor, constant: -8),
            commandLabel.centerYAnchor.constraint(equalTo: commandSegment.centerYAnchor),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        stack.addArrangedSubview(modeBadge)
        stack.addArrangedSubview(fileChip)
        stack.addArrangedSubview(branchChip)
        stack.addArrangedSubview(commandSegment)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(projectChip)
        stack.addArrangedSubview(lineColChip)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])

        render(model, dark: false)
    }

    /// Re-renders every chip from the model. Idempotent; call on every
    /// `superlemon.status` notification and on appearance changes.
    public func render(_ model: StatusModel, dark: Bool) {
        self.model = model
        self.isDark = dark

        layer?.backgroundColor = ShellPalette.surfaceBackground(dark: dark).cgColor
        topBorder.layer?.backgroundColor = ShellPalette.hairline(dark: dark).cgColor

        let badge = ShellPalette.modeBadge(model.mode, dark: dark)
        modeBadge.configure(
            text: model.mode.rawValue,
            textColor: badge.text,
            background: badge.background,
            bold: true
        )

        let chipBG = ShellPalette.statusChipBackground(dark: dark)
        let chipFG = ShellPalette.statusChipText(dark: dark)

        let fileName = model.file.isEmpty ? "[No Name]" : (model.file as NSString).lastPathComponent
        fileChip.configure(
            text: model.modified ? "\(fileName) ●" : fileName,
            textColor: chipFG,
            background: chipBG
        )

        if !model.branch.isEmpty {
            // U+2387 alternative to the Nerd-Font branch glyph; dimmed, no fill
            // per NORTHSTAR §4.1 ("branch glyph + name in dimmed gray, no fill").
            branchChip.configure(
                text: "⎇ \(model.branch)",
                textColor: ShellPalette.secondaryText(dark: dark),
                background: .clear
            )
        }

        if !model.project.isEmpty {
            projectChip.configure(text: model.project, textColor: chipFG, background: chipBG)
        }

        lineColChip.configure(
            text: "\(model.line):\(model.col)",
            textColor: ShellPalette.lineColText(dark: dark),
            background: ShellPalette.lineColBackground(dark: dark)
        )

        applyChipVisibility()
    }

    /// Command-line overlay for the flexible middle of the bar. Non-nil:
    /// shows the attributed command (mono, single line, tail-truncated,
    /// leading-aligned after the mode badge) and hides the file/branch/
    /// project chips; the mode badge and line:col cap stay visible. nil:
    /// restores the normal chips. `render(_:dark:)` during an active
    /// command keeps updating chip content but leaves them hidden until
    /// `renderCommand(nil)`.
    public func renderCommand(_ command: NSAttributedString?) {
        activeCommand = command
        commandLabel.attributedStringValue = command ?? NSAttributedString()
        applyChipVisibility()
    }

    private func applyChipVisibility() {
        let commandActive = activeCommand != nil
        commandSegment.isHidden = !commandActive
        fileChip.isHidden = commandActive
        branchChip.isHidden = commandActive || model.branch.isEmpty
        projectChip.isHidden = commandActive || model.project.isEmpty
    }
}

// MARK: - Chip

/// A flat colored capsule-less chip: mono label with horizontal padding on
/// an opaque fill (powerline chip minus the angled edge — square edges per
/// this wave; angle treatment is a later polish pass).
@MainActor
final class ChipView: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, textColor: NSColor, background: NSColor, bold: Bool = false) {
        label.stringValue = text
        label.textColor = textColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        layer?.backgroundColor = background.cgColor
    }

    var text: String { label.stringValue }
}
