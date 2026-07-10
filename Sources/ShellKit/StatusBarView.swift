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

/// One styled run of the user's evaluated statusline (CONTRACT.md
/// `superlemon.statusline`): powerline/lualine content with real colors.
public struct StatuslineSegment: Equatable, Sendable {
    public var text: String
    public var fg: UInt32?  // 0xRRGGBB; nil = bar default
    public var bg: UInt32?
    public var bold: Bool
    public var italic: Bool

    public init(
        text: String, fg: UInt32? = nil, bg: UInt32? = nil,
        bold: Bool = false, italic: Bool = false
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
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
    /// Synthesize Powerline glyphs (U+E0A0–A2, E0B0–B3) in harvested
    /// statusline segments as vector shape views — mirrors the grid
    /// renderer's setting; set by the app from the same preference.
    public var synthesizePowerline = false {
        didSet {
            if synthesizePowerline != oldValue, activeStatusline != nil {
                rebuildStatuslineStacks(activeStatusline, dark: isDark)
            }
        }
    }
    public private(set) var model = StatusModel()
    /// Non-nil while the command-line overlay occupies the flexible middle
    /// of the bar (see `renderCommand(_:)`).
    public private(set) var activeCommand: NSAttributedString?
    /// Non-nil while the bar displays the user's harvested statusline
    /// instead of the built-in chips (see `renderStatusline(_:)`).
    public private(set) var activeStatusline: [StatuslineSegment]?
    /// Harvested-statusline segments render as FULL-HEIGHT powerline blocks
    /// (two stacks around the flexible spacer) — attributed-label backgrounds
    /// only painted glyph line-height, leaving the bar visibly thinner than
    /// the command overlay.
    private let statuslineLeftStack = NSStackView()
    private let statuslineRightStack = NSStackView()
    /// The flexible gap between left/right content; painted with the
    /// statusline's own fill highlight while the harvested powerline shows.
    private let spacer = NSView()

    /// superlemon.ui statusbar segments (runtime/CONTRACT.md): namespace →
    /// (text, color). Rendered as chips AFTER all built-in content, composed
    /// sorted by namespace name. Visible in both chip and
    /// harvested-statusline modes; hidden while the command overlay is up.
    private var pluginSegments: [String: (text: String, color: NSColor?)] = [:]
    private var pluginChips: [ChipView] = []
    /// Composed plugin chip texts in render order (test hook).
    var pluginChipTexts: [String] { pluginChips.map(\.text) }

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

    /// Bar-content edge pins are 999, not required: an over-wide statusline
    /// (airline + a term://…fzf… buffer name was the field case) must clip
    /// inside the bar — a required chain here makes Auto Layout GROW THE
    /// WINDOW, triggering a resize feedback loop (window → columns →
    /// wider statusline → window…).
    private func pinned(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = .init(999)
        return constraint
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

        // Harvested-statusline segment (superlemon.statusline): a single
        // attributed line carrying the user's own powerline content.
        statuslineLeftStack.setAccessibilityIdentifier("status.statusline")
        statuslineRightStack.setAccessibilityIdentifier("status.statusline.right")
        for segStack in [statuslineLeftStack, statuslineRightStack] {
            segStack.isHidden = true
            segStack.orientation = .horizontal
            segStack.spacing = 0
            segStack.alignment = .centerY
        }
        statuslineLeftStack.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        statuslineRightStack.setContentCompressionResistancePriority(.init(251), for: .horizontal)

        spacer.wantsLayer = true
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        stack.addArrangedSubview(modeBadge)
        stack.addArrangedSubview(fileChip)
        stack.addArrangedSubview(branchChip)
        stack.addArrangedSubview(commandSegment)
        stack.addArrangedSubview(statuslineLeftStack)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(statuslineRightStack)
        stack.addArrangedSubview(projectChip)
        stack.addArrangedSubview(lineColChip)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            pinned(stack.leadingAnchor.constraint(equalTo: leadingAnchor)),
            pinned(stack.trailingAnchor.constraint(equalTo: trailingAnchor)),
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

        // Harvested statusline segments carry their own colors; rebuild so an
        // appearance flip re-resolves the default-foreground fallbacks.
        if activeStatusline != nil {
            rebuildStatuslineStacks(activeStatusline, dark: dark)
        }
        rebuildPluginChips()  // re-resolve default colors on appearance flips
        applyChipVisibility()
    }

    // MARK: superlemon.ui plugin segments (additive)

    /// Sets (or replaces) the plugin segment owned by `namespace`.
    /// `color` tints the chip text; nil uses the standard chip text color.
    public func setPluginSegment(namespace: String, text: String, color: NSColor? = nil) {
        pluginSegments[namespace] = (text, color)
        rebuildPluginChips()
        applyChipVisibility()
    }

    /// Removes `namespace`'s segment; other namespaces are untouched.
    public func clearPluginSegment(namespace: String) {
        guard pluginSegments.removeValue(forKey: namespace) != nil else { return }
        rebuildPluginChips()
        applyChipVisibility()
    }

    /// Rebuilds the trailing plugin chips, composed sorted by namespace
    /// name (the contract's deterministic composition order). Chips append
    /// after every built-in arranged view, so they sit at the bar's right
    /// edge in both chip and harvested-statusline modes.
    private func rebuildPluginChips() {
        for chip in pluginChips {
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        pluginChips = []
        for namespace in pluginSegments.keys.sorted() {
            guard let segment = pluginSegments[namespace] else { continue }
            let chip = ChipView()
            chip.setAccessibilityIdentifier("status.plugin.\(namespace)")
            chip.configure(
                text: segment.text,
                textColor: segment.color ?? ShellPalette.statusChipText(dark: isDark),
                background: ShellPalette.statusChipBackground(dark: isDark))
            stack.addArrangedSubview(chip)
            pluginChips.append(chip)
        }
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

    /// Display the user's evaluated statusline (powerline/lualine content,
    /// CONTRACT.md superlemon.statusline) INSTEAD of the built-in chips.
    /// nil or empty falls back to the chips. The command overlay still wins
    /// while a cmdline is active.
    public func renderStatusline(_ segments: [StatuslineSegment]?) {
        activeStatusline = (segments?.isEmpty ?? true) ? nil : segments
        rebuildStatuslineStacks(activeStatusline, dark: isDark)
        applyChipVisibility()
    }

    /// Split at the `%=` fill (a long run of spaces from nvim_eval_statusline)
    /// so the bar's own flexible spacer provides true right-alignment instead
    /// of hundreds of literal space characters.
    /// The private-use char the plugin evaluates `%=` fills as
    /// (runtime/lua/superlemon/statusline.lua) — unambiguous split marker.
    static let fillMarker: Character = "\u{E000}"

    /// Split at the `%=` fill so the bar's flexible spacer provides true
    /// right-alignment. Fill runs arrive as U+E000 characters (never real
    /// content); the fill segment's highlight colors the spacer. Falls back
    /// to the legacy ≥4-space heuristic when no marker is present (older
    /// runtime plugin).
    static func splitAtFill(
        _ segments: [StatuslineSegment]
    ) -> (left: [StatuslineSegment], right: [StatuslineSegment], fill: StatuslineSegment?) {
        if segments.contains(where: { $0.text.contains(fillMarker) }) {
            var left: [StatuslineSegment] = []
            var right: [StatuslineSegment] = []
            var fill: StatuslineSegment? = nil
            for segment in segments {
                if !segment.text.contains(fillMarker) {
                    if fill == nil { left.append(segment) } else { right.append(segment) }
                    continue
                }
                // First marker segment is THE fill; keep any real text around
                // the markers on the appropriate side.
                let parts = segment.text.split(
                    separator: fillMarker, omittingEmptySubsequences: true)
                var head = segment
                head.text = parts.first.map(String.init) ?? ""
                var tail = segment
                tail.text = parts.dropFirst().joined()
                if fill == nil {
                    if !head.text.isEmpty { left.append(head) }
                    fill = segment
                    if !tail.text.isEmpty { right.append(tail) }
                } else {
                    var cleaned = segment
                    cleaned.text = segment.text.filter { $0 != Self.fillMarker }
                    if !cleaned.text.isEmpty { right.append(cleaned) }
                }
            }
            return (left, right, fill)
        }

        // Legacy fallback: first ≥4-space run marks the fill.
        var left: [StatuslineSegment] = []
        var right: [StatuslineSegment] = []
        var fill: StatuslineSegment? = nil
        for segment in segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespaces)
            if fill == nil, trimmed.isEmpty, segment.text.count >= 4 {
                fill = segment
                continue
            }
            if fill == nil { left.append(segment) } else { right.append(segment) }
        }
        return (left, right, fill)
    }

    static func attributedStatusline(
        _ segments: [StatuslineSegment], dark: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            var font = NSFont.monospacedSystemFont(ofSize: 11, weight: segment.bold ? .semibold : .regular)
            if segment.italic,
                let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as NSFont?
            {
                font = italic
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: segment.fg.map(Self.color)
                    ?? ShellPalette.primaryText(dark: dark),
            ]
            if let bg = segment.bg { attrs[.backgroundColor] = Self.color(bg) }
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result
    }

    private static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    /// Rebuild the two segment stacks as full-height colored blocks.
    private func rebuildStatuslineStacks(_ segments: [StatuslineSegment]?, dark: Bool) {
        for segStack in [statuslineLeftStack, statuslineRightStack] {
            segStack.arrangedSubviews.forEach {
                segStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
        guard let segments else {
            spacer.layer?.backgroundColor = nil
            return
        }
        let (left, right, fill) = Self.splitAtFill(segments)
        spacer.layer?.backgroundColor = fill?.bg.map { Self.colorFromRGB($0).cgColor } ?? nil
        for (side, stackView) in [(left, statuslineLeftStack), (right, statuslineRightStack)] {
            for var segment in side {
                // Collapse residual fill runs (airline pads sections with
                // literal spaces up to the eval width) — the bar's spacer
                // owns alignment; giant space runs must not demand width.
                segment.text = segment.text.replacingOccurrences(
                    of: "   +", with: "  ", options: .regularExpression)
                stackView.addArrangedSubview(segmentBlock(segment, dark: dark))
            }
        }
    }

    /// One powerline block: opaque full-bar-height fill; text runs render as
    /// labels, powerline scalars as vector shape views (when enabled).
    private func segmentBlock(_ segment: StatuslineSegment, dark: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        if let bg = segment.bg {
            container.layer?.backgroundColor = Self.colorFromRGB(bg).cgColor
        }
        var font = NSFont.monospacedSystemFont(
            ofSize: 11, weight: segment.bold ? .semibold : .regular)
        if segment.italic,
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                as NSFont?
        {
            font = italic
        }
        let fg = segment.fg.map(Self.colorFromRGB) ?? ShellPalette.primaryText(dark: dark)

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = fg
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            // Truncate rather than demand width (long paths, term:// names).
            label.setContentCompressionResistancePriority(.init(240), for: .horizontal)
            return label
        }

        let tokens =
            synthesizePowerline
            ? PowerlineGlyph.tokenize(segment.text)
            : [(text: segment.text, isGlyph: false)]
        let content = NSStackView()
        content.orientation = .horizontal
        content.spacing = 0
        content.alignment = .centerY
        for token in tokens {
            if token.isGlyph, let scalar = token.text.unicodeScalars.first {
                content.addArrangedSubview(
                    PowerlineShapeView(
                        scalar: scalar, color: fg, height: StatusBarView.barHeight - 1))
            } else {
                content.addArrangedSubview(label(token.text))
            }
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            // Full bar height minus the 1px top border: blocks reach the
            // bar's edges like the command overlay does.
            container.heightAnchor.constraint(equalToConstant: StatusBarView.barHeight - 1),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.heightAnchor.constraint(equalTo: container.heightAnchor),
        ])
        return container
    }

    private static func colorFromRGB(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    private func applyChipVisibility() {
        let commandActive = activeCommand != nil
        let statuslineActive = !commandActive && activeStatusline != nil
        commandSegment.isHidden = !commandActive
        statuslineLeftStack.isHidden = !statuslineActive
        statuslineRightStack.isHidden = !statuslineActive
        // The harvested statusline carries everything (mode, file, position),
        // so ALL chips yield to it; the command overlay keeps mode + line:col.
        modeBadge.isHidden = statuslineActive
        lineColChip.isHidden = statuslineActive
        fileChip.isHidden = commandActive || statuslineActive
        branchChip.isHidden = commandActive || statuslineActive || model.branch.isEmpty
        projectChip.isHidden = commandActive || statuslineActive || model.project.isEmpty
        // Plugin segments stay up alongside chips AND the harvested
        // statusline; only the command overlay hides them.
        for chip in pluginChips { chip.isHidden = commandActive }
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
