// FileTreeCells — row/cell views shared between FileTreeSidebarView
// (NSOutlineView, docs/design/surface-navbar-v1.md's "legacy" sidebar) and
// TreeSurfaceView (NSTableView, the surface-mode navbar, §8). Promoted out
// of FileTreeSidebarView.swift so both controls get pixel parity BY
// CONSTRUCTION rather than by keeping two implementations in sync.
//
// The `FileTreeSidebarView`-facing API on these types (`configure(node:)`,
// `configureAsParentDirectory`, `configure(state:onRetry:)`, `beginEditing`,
// `commitEditingName`, …) is UNCHANGED from the pre-split file — moving code
// here must not alter sidebar behavior. Everything under the "TreeSurfaceView
// seam" headings below is additive: default-off / default-hidden state that
// the sidebar's call sites never touch.

import AppKit

// MARK: - Row view

@MainActor
final class FileTreeRowView: NSTableRowView {
    private let dark: Bool

    /// TreeSurfaceView seam: emphasized (accent-colored) vs. secondary (gray,
    /// the sidebar's only style) selection. The sidebar always constructs
    /// this with the default `emphasized: false` and never touches
    /// `isRowEmphasized` afterwards, so its selection color is unchanged.
    var isRowEmphasized: Bool

    init(dark: Bool, emphasized: Bool = false) {
        self.dark = dark
        self.isRowEmphasized = emphasized
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        if isRowEmphasized {
            // The system list-selection blue (lighter than the raw accent
            // color, tracks the user's accent preference) — TreeSurfaceView
            // uses this when its navbar window is the current vim window.
            NSColor.selectedContentBackgroundColor.setFill()
        } else {
            // Full-width square-edged fill (#EAEAEA light / #343434 dark).
            ShellPalette.sidebarSelection(dark: dark).setFill()
        }
        bounds.fill()
    }
}

// MARK: - Loading / failed placeholder cell

@MainActor
final class FileTreePlaceholderCellView: NSView {
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var onRetry: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Loading folder")

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .inline
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinner)
        addSubview(messageLabel)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            messageLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 5),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 6),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(state: FileTreeLoadState, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch state {
        case .unloaded, .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            messageLabel.stringValue = "Loading…"
            messageLabel.toolTip = nil
            retryButton.isHidden = true
        case .failed(let description):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = "Couldn’t load folder"
            messageLabel.toolTip = description
            retryButton.isHidden = false
        case .loaded:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = ""
            retryButton.isHidden = true
        }
    }

    /// TreeSurfaceView seam: the model's `.loading`/`.failed` row kinds carry
    /// no FileTreeNode, just a row label (used as the failure/loading
    /// message when non-empty). `onRetry` routes to `onOpen(id, false)` —
    /// the design's "failed row click → treat as activate" rule.
    func configure(kind: TreeSurfaceRow.Kind, message: String, onRetry: @escaping () -> Void) {
        switch kind {
        case .loading:
            configure(state: .loading, onRetry: onRetry)
        case .failed:
            configure(state: .failed(message), onRetry: onRetry)
        default:
            configure(state: .loaded, onRetry: onRetry)
        }
    }

    @objc private func retryClicked() { onRetry?() }
}

// MARK: - Name / dot / badge cell

@MainActor
final class FileTreeCellView: NSView {
    private let chevronButton = NSButton(
        image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            ?? NSImage(),
        target: nil, action: nil)
    private let dotLabel = NSTextField(labelWithString: "●")
    private let nameLabel = NSTextField(labelWithString: "")
    private let gitBadgeLabel = NSTextField(labelWithString: "")
    private var commitHandler: ((String) -> Void)?
    private var dotLeadingConstraint: NSLayoutConstraint!
    private var chevronLeadingConstraint: NSLayoutConstraint!

    /// TreeSurfaceView seam: fires when the disclosure chevron is clicked.
    /// The sidebar never sets this (it has no chevron button — the outline
    /// view draws its own disclosure triangle).
    var onChevronTap: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.imageScaling = .scaleProportionallyDown
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.isHidden = true
        chevronButton.setAccessibilityIdentifier("surface.cell.chevron")
        chevronButton.target = self
        chevronButton.action = #selector(chevronClicked)

        dotLabel.font = .systemFont(ofSize: 9)
        dotLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setAccessibilityIdentifier("sidebar.cell.name")
        nameLabel.delegate = self
        gitBadgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        gitBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBadgeLabel.setAccessibilityIdentifier("sidebar.cell.gitBadge")
        gitBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        gitBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(chevronButton)
        addSubview(dotLabel)
        addSubview(nameLabel)
        addSubview(gitBadgeLabel)
        let chevronLeading = chevronButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 4)
        let dotLeading = dotLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        chevronLeadingConstraint = chevronLeading
        dotLeadingConstraint = dotLeading
        NSLayoutConstraint.activate([
            chevronLeading,
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 10),
            chevronButton.heightAnchor.constraint(equalToConstant: 10),
            dotLeading,
            // Fixed width so file names align whether the row shows a type
            // dot (files) or nothing (directories — the outline view's own
            // disclosure triangle is the only indicator).
            dotLabel.widthAnchor.constraint(equalToConstant: 12),
            dotLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: gitBadgeLabel.leadingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(node: FileTreeNode, dark: Bool) {
        nameLabel.stringValue = node.name
        nameLabel.textColor = ShellPalette.primaryText(dark: dark)
        if node.isDirectory {
            // No glyph: the outline view's disclosure triangle already marks
            // directories — a second arrow here reads as a double chevron.
            dotLabel.stringValue = ""
        } else {
            dotLabel.stringValue = "●"
            dotLabel.textColor = ShellPalette.fileTypeColor(
                forExtension: node.url.pathExtension, dark: dark
            )
        }
        gitBadgeLabel.stringValue = ""  // reset; the sidebar re-applies per row
        endEditing(commit: false)
    }

    /// The synthetic ".." row: secondary-colored, no type dot, no badge.
    /// The parent folder's name rides along further dimmed so "up" has a
    /// visible destination; the full path stays in the tooltip.
    func configureAsParentDirectory(parentPath: String, dark: Bool) {
        let parentName = (parentPath as NSString).lastPathComponent
        let font = nameLabel.font ?? .systemFont(ofSize: 13)
        let secondary = ShellPalette.secondaryText(dark: dark)
        let text = NSMutableAttributedString(
            string: "..",
            attributes: [.font: font, .foregroundColor: secondary])
        if !parentName.isEmpty {
            text.append(NSAttributedString(
                string: "  \(parentName)",
                attributes: [
                    .font: font,
                    .foregroundColor: secondary.withAlphaComponent(0.65),
                ]))
        }
        nameLabel.attributedStringValue = text
        dotLabel.stringValue = ""
        gitBadgeLabel.stringValue = ""
        toolTip = "Go to parent folder: \(parentPath)"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Parent folder \(parentName)")
        endEditing(commit: false)
    }

    /// NERDTree-git-style trailing badge (M/A/D/R/?/• for dirty dirs).
    func setGitBadge(_ text: String, color: NSColor) {
        gitBadgeLabel.stringValue = text
        gitBadgeLabel.textColor = color
    }

    func beginEditing(onCommit: @escaping (String) -> Void) {
        commitHandler = onCommit
        nameLabel.isEditable = true
        nameLabel.isBezeled = true
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    var displayedName: String { nameLabel.stringValue }

    /// Deterministic accessibility/test seam for committing the same text an
    /// inline editor would submit through its field-editor callback.
    func commitEditingName(_ name: String) {
        guard nameLabel.isEditable else { return }
        nameLabel.stringValue = name
        endEditing(commit: true)
    }

    private func endEditing(commit: Bool) {
        guard nameLabel.isEditable else { return }
        let handler = commitHandler
        commitHandler = nil
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        if commit { handler?(nameLabel.stringValue) }
    }

    // MARK: TreeSurfaceView seam

    /// Generalized `configure(node:dark:)` for a flat `TreeSurfaceRow`
    /// (TreeSurfaceView has no FileTreeNode) — same visual rules: type dot
    /// colored by extension for files, blank for directories, plus manual
    /// depth indentation and a disclosure chevron (the outline view's own
    /// triangle has no equivalent on a flat NSTableView).
    func configure(row: TreeSurfaceRow, dark: Bool) {
        nameLabel.stringValue = row.label
        nameLabel.textColor = ShellPalette.primaryText(dark: dark)
        // Explicit tint: the template chevron otherwise resolves against the
        // window's appearance, not the navbar's painted background, and
        // disappears (white-on-white in a dark-appearance window).
        chevronButton.contentTintColor = ShellPalette.secondaryText(dark: dark)
        if row.kind == .dir {
            dotLabel.stringValue = ""
        } else {
            dotLabel.stringValue = "●"
            let ext = (row.label as NSString).pathExtension
            dotLabel.textColor = ShellPalette.fileTypeColor(forExtension: ext, dark: dark)
        }
        if let badge = row.badge {
            gitBadgeLabel.stringValue = badge.text
            gitBadgeLabel.textColor = badge.colorHex.flatMap(UIColorHex.parse)
                ?? ShellPalette.secondaryText(dark: dark)
        } else if let dotHex = row.dotColorHex {
            gitBadgeLabel.stringValue = "•"
            gitBadgeLabel.textColor = UIColorHex.parse(dotHex)
                ?? ShellPalette.secondaryText(dark: dark)
        } else {
            gitBadgeLabel.stringValue = ""
        }
        toolTip = row.id
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(row.label)
        configureIndent(depth: row.depth, showsChevron: row.kind == .dir, expanded: row.expanded)
        endEditing(commit: false)
    }

    /// Positions the disclosure chevron and indents the dot/name/badge group
    /// `depth` levels (17pt/level, matching
    /// `FileTreeSidebarView.indentPerLevel`). The sidebar never calls this,
    /// so its cells keep the original fixed 4pt leading inset.
    func configureIndent(depth: Int, showsChevron: Bool, expanded: Bool) {
        let base: CGFloat = 4
        let perLevel: CGFloat = 17
        let chevronSpace: CGFloat = 14
        chevronButton.isHidden = !showsChevron
        chevronLeadingConstraint.constant = base + CGFloat(depth) * perLevel
        dotLeadingConstraint.constant = base + CGFloat(depth) * perLevel
            + (showsChevron ? chevronSpace : 0)
        if showsChevron {
            chevronButton.image = NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil)
        }
    }

    @objc private func chevronClicked() { onChevronTap?() }
}

extension FileTreeCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endEditing(commit: true)
    }
}
