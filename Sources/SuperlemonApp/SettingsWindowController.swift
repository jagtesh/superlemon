// Settings window (⌘,): choose which Neovim init is loaded and open the
// user-owned Superlemon init.vim. All editor/chrome/renderer preferences
// live in that documented file instead of a second UserDefaults store.

import AppKit

@MainActor
final class SettingsWindowController: NSObject {
    static let customInitPathKey = "CustomInitPath"

    private var window: NSWindow?
    private let useMyConfigCheckbox = NSButton(
        checkboxWithTitle: "Use my Neovim config (init.vim / init.lua)",
        target: nil, action: nil)
    private let customPathField = NSTextField(string: "")
    private let relaunchNote = NSTextField(
        wrappingLabelWithString:
            "Configuration source and Superlemon init.vim changes apply when the app relaunches.")

    var onEditSuperlemonConfig: (() -> Void)?
    var onRelaunch: (() -> Void)?

    func show() {
        if window == nil { build() }
        loadValues()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 270),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        useMyConfigCheckbox.target = self
        useMyConfigCheckbox.action = #selector(toggleUseMyConfig)
        customPathField.placeholderString =
            "Custom init file (overrides both) — empty = selection above"
        customPathField.target = self
        customPathField.action = #selector(pathEdited)

        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        let pathRow = NSStackView(views: [customPathField, browse])
        pathRow.orientation = .horizontal

        let editButton = NSButton(
            title: "Edit Superlemon Configuration…",
            target: self, action: #selector(editSuperlemonConfig))
        editButton.toolTip =
            "Creates and opens $XDG_CONFIG_HOME/superlemon/init.vim (normally ~/.config/superlemon/init.vim)."

        relaunchNote.textColor = .secondaryLabelColor
        relaunchNote.font = .systemFont(ofSize: 11)
        let relaunchButton = NSButton(
            title: "Relaunch Now", target: self, action: #selector(relaunch))

        let stack = NSStackView(views: [
            sectionLabel("NEOVIM CONFIGURATION"),
            useMyConfigCheckbox, pathRow,
            sectionLabel("SUPERLEMON SETTINGS"),
            editButton, relaunchNote, relaunchButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: pathRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
            customPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        self.window = window
    }

    private func loadValues() {
        let defaults = UserDefaults.standard
        useMyConfigCheckbox.state =
            defaults.bool(forKey: NvimController.managedConfigDefaultsKey) ? .off : .on
        customPathField.stringValue = defaults.string(forKey: Self.customInitPathKey) ?? ""
    }

    @objc private func toggleUseMyConfig() {
        UserDefaults.standard.set(
            useMyConfigCheckbox.state == .off,
            forKey: NvimController.managedConfigDefaultsKey)
    }

    @objc private func pathEdited() {
        let value = customPathField.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.customInitPathKey)
        } else {
            UserDefaults.standard.set(value, forKey: Self.customInitPathKey)
        }
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customPathField.stringValue = url.path
            pathEdited()
        }
    }

    @objc private func editSuperlemonConfig() {
        onEditSuperlemonConfig?()
        window?.close()
    }

    @objc private func relaunch() {
        pathEdited()
        onRelaunch?()
    }
}
