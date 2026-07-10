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
    private let fontNameField = NSTextField(string: "")
    private let fontSizeField = NSTextField(string: "")
    private let symbolFontCheckbox = NSButton(
        checkboxWithTitle: "Use a different font for symbols (bundled FiraCode Nerd Font)",
        target: nil, action: nil)
    private let powerlineCheckbox = NSButton(
        checkboxWithTitle: "Powerline symbols", target: nil, action: nil)
    private let ligaturesCheckbox = NSButton(
        checkboxWithTitle: "Font ligatures", target: nil, action: nil)
    private let forceFallbackCheckbox = NSButton(
        checkboxWithTitle: "Force built-in fallback rendering (no font required)",
        target: nil, action: nil)

    private let relaunchNote = NSTextField(
        wrappingLabelWithString:
            "Configuration and startup settings apply when Superlemon relaunches; appearance settings apply immediately.")

    var onEditManagedConfig: (() -> Void)?
    var onRelaunch: (() -> Void)?

    init(controller: NvimController) {
        self.controller = controller
        super.init()
    }

    /// Live-sync: re-read values while the window is visible (font bumps,
    /// guifont changes, font-panel picks).
    func refresh() {
        if window?.isVisible == true { loadValues() }
    }

    func show() {
        if window == nil { build() }
        loadValues()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func fontRow() -> NSStackView {
        let choose = NSButton(title: "Choose…", target: self, action: #selector(showFontPanel))
        let row = NSStackView(views: [fontNameField, fontSizeField, choose])
        row.orientation = .horizontal
        fontNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        fontSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return row
    }

    /// Native NSFontPanel: selections stream through changeFont(_:) for
    /// LIVE preview in the editor while browsing.
    @objc private func showFontPanel(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        let size = Double(fontSizeField.stringValue) ?? 13
        let current =
            NSFont(name: fontNameField.stringValue, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(sender)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let base = NSFont(
            name: fontNameField.stringValue,
            size: Double(fontSizeField.stringValue) ?? 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let chosen = manager.convert(base)
        fontNameField.stringValue = chosen.fontName
        fontSizeField.stringValue = String(Int(chosen.pointSize))
        appearanceToggled()  // persist + apply live
    }

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

        fontNameField.placeholderString = "Editor font (empty = follow guifont)"
        fontNameField.target = self
        fontNameField.action = #selector(appearanceToggled)
        fontSizeField.placeholderString = "Size"
        fontSizeField.target = self
        fontSizeField.action = #selector(appearanceToggled)
        for box in [symbolFontCheckbox, powerlineCheckbox, ligaturesCheckbox, forceFallbackCheckbox] {
            box.target = self
            box.action = #selector(appearanceToggled)
        }
        symbolFontCheckbox.toolTip =
            "Ligatures and plugin symbols render through FiraCode Nerd Font Mono while text keeps your font."
        forceFallbackCheckbox.toolTip =
            "Superlemon draws Powerline shapes and substitutes Unicode ligature equivalents itself."


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
            fontRow(),
            symbolFontCheckbox, powerlineCheckbox, ligaturesCheckbox, forceFallbackCheckbox,
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
        fontNameField.stringValue = defaults.string(forKey: "EditorFontName") ?? ""
        let size = defaults.double(forKey: "EditorFontSize")
        fontSizeField.stringValue = size > 0 ? String(Int(size)) : ""
        // Placeholders mirror the LIVE editor font, so an empty field always
        // tells the truth about what is rendering right now.
        if let spec = controller.currentFontSpec {
            fontNameField.placeholderString =
                (spec.name ?? "System Mono") + "  (from config)"
            fontSizeField.placeholderString = String(Int(spec.size))
        }
        symbolFontCheckbox.state = defaults.bool(forKey: "UseSymbolFont") ? .on : .off
        forceFallbackCheckbox.state = defaults.bool(forKey: "ForceGlyphFallback") ? .on : .off
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
        defaults.set(symbolFontCheckbox.state == .on, forKey: "UseSymbolFont")
        defaults.set(forceFallbackCheckbox.state == .on, forKey: "ForceGlyphFallback")
        let name = fontNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            defaults.removeObject(forKey: "EditorFontName")
        } else {
            defaults.set(name, forKey: "EditorFontName")
        }
        if let size = Double(fontSizeField.stringValue), size >= 6, size <= 72 {
            defaults.set(size, forKey: "EditorFontSize")
        } else {
            defaults.removeObject(forKey: "EditorFontSize")
        }
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
