// Settings window (⌘,): configuration source and the managed init.lua.

import AppKit

@MainActor
final class SettingsWindowController: NSObject {
    static let customInitPathKey = "CustomInitPath"

    private var window: NSWindow?
    private unowned let controller: NvimController
    private let useMyConfigCheckbox = NSButton(
        checkboxWithTitle: "Use my Neovim config (init.vim / init.lua)",
        target: nil, action: nil)
    private let customPathField = NSTextField(string: "")
    private let relaunchNote = NSTextField(
        wrappingLabelWithString: "Configuration changes apply when Superlemon relaunches.")

    /// The managed config path (runtime/config/init.lua), if resolvable.
    var onEditManagedConfig: (() -> Void)?
    var onRelaunch: (() -> Void)?

    init(controller: NvimController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if window == nil { build() }
        loadValues()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        useMyConfigCheckbox.target = self
        useMyConfigCheckbox.action = #selector(toggleUseMyConfig)

        let pathLabel = NSTextField(labelWithString: "Custom init file (overrides both):")
        customPathField.placeholderString = "empty = use the selection above"
        customPathField.target = self
        customPathField.action = #selector(pathEdited)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        let pathRow = NSStackView(views: [customPathField, browse])
        pathRow.orientation = .horizontal

        let editButton = NSButton(
            title: "Edit Superlemon init.lua…", target: self, action: #selector(editManaged))
        editButton.toolTip =
            "Opens the built-in configuration (powerline colors/segments, plugins) in the editor."
        let relaunchButton = NSButton(
            title: "Relaunch Now", target: self, action: #selector(relaunch))
        let buttonRow = NSStackView(views: [editButton, relaunchButton])
        buttonRow.orientation = .horizontal

        relaunchNote.textColor = .secondaryLabelColor
        relaunchNote.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            useMyConfigCheckbox, pathLabel, pathRow, buttonRow, relaunchNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            customPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
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

    @objc private func editManaged() {
        onEditManagedConfig?()
        window?.close()
    }

    @objc private func relaunch() {
        pathEdited()
        onRelaunch?()
    }
}
