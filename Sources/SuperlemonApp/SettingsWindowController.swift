// Settings window (⌘,): configuration source, startup chrome defaults,
// and appearance options (Powerline glyph synthesis, ligatures).

import AppKit

@MainActor
final class SettingsWindowController: NSObject {
    static let customInitPathKey = "CustomInitPath"

    private var window: NSWindow?
    private unowned let controller: NvimController

    // Configuration source
    private let useMyConfigCheckbox = NSButton(
        checkboxWithTitle: "Use my Neovim config (init.vim / init.lua)",
        target: nil, action: nil)
    private let customPathField = NSTextField(string: "")

    // On startup
    private let combinedCheckbox = NSButton(
        checkboxWithTitle: "Use native tabs and command bar",
        target: nil, action: nil)
    private let customizeButton = NSButton(
        title: "Customize…", target: nil, action: nil)
    private let fineTabs = NSButton(
        checkboxWithTitle: "Native buffer tabs", target: nil, action: nil)
    private let fineBar = NSButton(
        checkboxWithTitle: "Native command bar (status line + command input)",
        target: nil, action: nil)
    private let fineHideTabline = NSButton(
        checkboxWithTitle: "Hide the editor's own tab line (e.g. airline tabs)",
        target: nil, action: nil)
    private let fineAdopt = NSButton(
        checkboxWithTitle: "Hide the editor's own status line (shown in the native bar instead)",
        target: nil, action: nil)
    private var fineStack: NSStackView!

    // Appearance
    private let powerlineCheckbox = NSButton(
        checkboxWithTitle: "Draw Powerline symbols with any font",
        target: nil, action: nil)
    private let ligaturesCheckbox = NSButton(
        checkboxWithTitle: "Enable font ligatures", target: nil, action: nil)

    private let relaunchNote = NSTextField(
        wrappingLabelWithString:
            "Configuration and startup settings apply when Superlemon relaunches; appearance settings apply immediately.")

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

    // MARK: - UI

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        useMyConfigCheckbox.target = self
        useMyConfigCheckbox.action = #selector(toggleUseMyConfig)
        customPathField.placeholderString = "Custom init file (overrides both) — empty = selection above"
        customPathField.target = self
        customPathField.action = #selector(pathEdited)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browse))
        let pathRow = NSStackView(views: [customPathField, browse])
        pathRow.orientation = .horizontal
        let editButton = NSButton(
            title: "Edit Superlemon init.lua…", target: self, action: #selector(editManaged))
        editButton.toolTip =
            "The built-in configuration: powerline colors and segments, plugins (vim.pack), defaults."

        combinedCheckbox.target = self
        combinedCheckbox.action = #selector(combinedToggled)
        customizeButton.target = self
        customizeButton.action = #selector(customizeTapped)
        customizeButton.bezelStyle = .inline
        let combinedRow = NSStackView(views: [combinedCheckbox, customizeButton])
        combinedRow.orientation = .horizontal
        for fine in [fineTabs, fineBar, fineHideTabline, fineAdopt] {
            fine.target = self
            fine.action = #selector(fineToggled)
        }
        fineStack = NSStackView(views: [fineTabs, fineBar, fineHideTabline, fineAdopt])
        fineStack.orientation = .vertical
        fineStack.alignment = .leading
        fineStack.spacing = 6
        fineStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        fineStack.isHidden = true

        powerlineCheckbox.target = self
        powerlineCheckbox.action = #selector(appearanceToggled)
        powerlineCheckbox.toolTip =
            "Synthesizes the Powerline separators and branch symbol (U+E0A0, U+E0B0–B3) as vector shapes — no patched font needed."
        ligaturesCheckbox.target = self
        ligaturesCheckbox.action = #selector(appearanceToggled)

        relaunchNote.textColor = .secondaryLabelColor
        relaunchNote.font = .systemFont(ofSize: 11)
        let relaunchButton = NSButton(
            title: "Relaunch Now", target: self, action: #selector(relaunch))

        let stack = NSStackView(views: [
            sectionLabel("CONFIGURATION"),
            useMyConfigCheckbox, pathRow, editButton,
            sectionLabel("APPLY THESE SETTINGS ON STARTUP"),
            combinedRow, fineStack,
            sectionLabel("APPEARANCE"),
            powerlineCheckbox, ligaturesCheckbox,
            relaunchNote, relaunchButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: editButton)
        stack.setCustomSpacing(18, after: fineStack)
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

        let mode = defaults.string(forKey: "StartupChromeMode")
        let customizing = mode == "custom"
        fineStack.isHidden = !customizing
        combinedCheckbox.isEnabled = !customizing
        combinedCheckbox.state =
            (mode == "combined" && defaults.bool(forKey: "StartupChromeCombinedOn")) ? .on : .off
        fineTabs.state = defaults.bool(forKey: "StartupNativeTabs") ? .on : .off
        fineBar.state = defaults.bool(forKey: "StartupNativeBar") ? .on : .off
        fineHideTabline.state = defaults.bool(forKey: "StartupHideTabline") ? .on : .off
        fineAdopt.state = defaults.bool(forKey: "StartupAdoptStatusline") ? .on : .off
        customizeButton.title = customizing ? "Use the simple option" : "Customize…"

        powerlineCheckbox.state = defaults.bool(forKey: "PowerlineGlyphs") ? .on : .off
        let ligatures =
            defaults.object(forKey: "Ligatures") == nil ? true : defaults.bool(forKey: "Ligatures")
        ligaturesCheckbox.state = ligatures ? .on : .off
    }

    // MARK: - Actions

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

    @objc private func combinedToggled() {
        let defaults = UserDefaults.standard
        defaults.set("combined", forKey: "StartupChromeMode")
        defaults.set(combinedCheckbox.state == .on, forKey: "StartupChromeCombinedOn")
    }

    @objc private func customizeTapped() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "StartupChromeMode") == "custom" {
            defaults.set("combined", forKey: "StartupChromeMode")
        } else {
            defaults.set("custom", forKey: "StartupChromeMode")
            // Seed the fine controls from the combined choice.
            let on = combinedCheckbox.state == .on
            defaults.set(on, forKey: "StartupNativeTabs")
            defaults.set(on, forKey: "StartupNativeBar")
            defaults.set(on, forKey: "StartupHideTabline")
            defaults.set(on, forKey: "StartupAdoptStatusline")
        }
        loadValues()
    }

    @objc private func fineToggled() {
        let defaults = UserDefaults.standard
        defaults.set("custom", forKey: "StartupChromeMode")
        defaults.set(fineTabs.state == .on, forKey: "StartupNativeTabs")
        defaults.set(fineBar.state == .on, forKey: "StartupNativeBar")
        defaults.set(fineHideTabline.state == .on, forKey: "StartupHideTabline")
        defaults.set(fineAdopt.state == .on, forKey: "StartupAdoptStatusline")
    }

    @objc private func appearanceToggled() {
        let defaults = UserDefaults.standard
        defaults.set(powerlineCheckbox.state == .on, forKey: "PowerlineGlyphs")
        defaults.set(ligaturesCheckbox.state == .on, forKey: "Ligatures")
        controller.applyRenderingOptions()  // immediate, no relaunch
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
