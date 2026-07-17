// FileTransferProgressView — the sidebar's bottom transfer band. Appears
// while a drag-and-drop batch is streaming (WorkspaceFileTransfer.swift):
// direction glyph, current file name, "(k of n)" counter, a determinate
// bar for overall progress, and a cancel button. UI-only; the embedder
// feeds it WorkspaceTransferProgress values and reacts to onCancel.

import AppKit

@MainActor
public final class FileTransferProgressView: NSView {
    public static let bandHeight: CGFloat = 46

    public var onCancel: (() -> Void)?

    private let directionLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "✕", target: nil, action: nil)
    private let bar = NSProgressIndicator()
    private let hairline = NSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true

        directionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setAccessibilityIdentifier("sidebar.transfer.name")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.setAccessibilityIdentifier("sidebar.transfer.count")
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 10, weight: .bold)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.setAccessibilityLabel("Cancel file transfer")
        cancelButton.setAccessibilityIdentifier("sidebar.transfer.cancel")

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.setAccessibilityIdentifier("sidebar.transfer.bar")

        hairline.wantsLayer = true

        for view in [directionLabel, nameLabel, countLabel, cancelButton, bar, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            directionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            directionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: directionLabel.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: directionLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: directionLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -6),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            cancelButton.centerYAnchor.constraint(equalTo: directionLabel.centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyAppearance(dark: false)
    }

    public func applyAppearance(dark: Bool) {
        layer?.backgroundColor = ShellPalette.surfaceBackground(dark: dark).cgColor
        hairline.layer?.backgroundColor = ShellPalette.hairline(dark: dark).cgColor
        nameLabel.textColor = ShellPalette.primaryText(dark: dark)
        directionLabel.textColor = ShellPalette.secondaryText(dark: dark)
        countLabel.textColor = ShellPalette.secondaryText(dark: dark)
    }

    /// Feeds the band one progress snapshot; the embedder hides the band by
    /// rendering nil (handled by the sidebar's height collapse).
    public func render(_ progress: WorkspaceTransferProgress) {
        directionLabel.stringValue = progress.incoming ? "↓" : "↑"
        nameLabel.stringValue = progress.itemName
        countLabel.stringValue =
            progress.totalItems > 1
            ? "\(min(progress.completedItems + 1, progress.totalItems)) of \(progress.totalItems)"
            : ""
        bar.doubleValue = progress.overallFraction
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
