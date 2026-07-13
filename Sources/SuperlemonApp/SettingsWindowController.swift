// Settings window (⌘,): choose exactly one Neovim initialization source and
// open the corresponding configuration. Editor/chrome/renderer preferences
// remain in Vim configuration rather than a second native settings store.

import AppKit
import EditorHostKit

@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var selection = NvimConfigSelection(mode: .managed, customInitPath: nil)

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeDescription = NSTextField(wrappingLabelWithString: "")
    private let customPathField = NSTextField(string: "")
    private let browseButton = NSButton(title: "Browse…", target: nil, action: nil)
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit Configuration…", target: nil, action: nil)
    private let relaunchButton = NSButton(title: "Relaunch Now", target: nil, action: nil)
    private let relaunchNote = NSTextField(
        wrappingLabelWithString: "Configuration-source changes apply when the app relaunches.")

    /// Mode-aware hook; NvimController owns file creation/opening through
    /// Neovim so the selected configuration remains the single authority.
    var onEditConfiguration: ((NvimConfigSelection) -> Void)?
    var onRelaunch: (() -> Void)?

    func show() {
        if window == nil { build() }
        selection = NvimConfigPreferences.loadAndMigrate()
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        for mode in NvimConfigMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        modeDescription.textColor = .secondaryLabelColor
        modeDescription.font = .systemFont(ofSize: 11)

        customPathField.placeholderString = "/absolute/path/to/init.lua"
        customPathField.delegate = self
        customPathField.target = self
        customPathField.action = #selector(pathEdited)

        browseButton.target = self
        browseButton.action = #selector(browse)
        let pathRow = NSStackView(views: [customPathField, browseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: 11)

        editButton.target = self
        editButton.action = #selector(editConfiguration)

        relaunchNote.textColor = .secondaryLabelColor
        relaunchNote.font = .systemFont(ofSize: 11)
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)

        let stack = NSStackView(views: [
            sectionLabel("NEOVIM CONFIGURATION"),
            modePopup,
            modeDescription,
            pathRow,
            validationLabel,
            sectionLabel("CONFIGURATION FILE"),
            editButton,
            relaunchNote,
            relaunchButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: validationLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
            modePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            customPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            modeDescription.widthAnchor.constraint(lessThanOrEqualToConstant: 510),
            validationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 510),
        ])
        self.window = window
    }

    private func loadValues() {
        modePopup.selectItem(at: NvimConfigMode.allCases.firstIndex(of: selection.mode) ?? 0)
        customPathField.stringValue = selection.customInitPath ?? ""
        updateControls()
    }

    private var selectedMode: NvimConfigMode {
        let index = modePopup.indexOfSelectedItem
        guard NvimConfigMode.allCases.indices.contains(index) else { return .managed }
        return NvimConfigMode.allCases[index]
    }

    private func persistValues() {
        let path = customPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = NvimConfigSelection(
            mode: selectedMode,
            customInitPath: path.isEmpty ? nil : path)
        NvimConfigPreferences.save(selection)
    }

    private func updateControls() {
        let mode = selectedMode
        let custom = mode == .custom
        customPathField.isEnabled = custom
        browseButton.isEnabled = custom

        switch mode {
        case .managed:
            modeDescription.stringValue =
                "Uses bundled defaults, then sources $XDG_CONFIG_HOME/superlemon/init.vim once (normally ~/.config/superlemon/init.vim)."
            editButton.title = "Edit Superlemon Overrides…"
            editButton.toolTip = "Open the resolved Superlemon personal override."
        case .user:
            modeDescription.stringValue =
                "Uses Neovim's normal init and does not apply Superlemon's managed configuration afterward."
            editButton.title = "Edit My Neovim Configuration…"
            editButton.toolTip = "Open the normal ~/.config/nvim init file."
        case .custom:
            modeDescription.stringValue =
                "Sources only the selected init once; no managed defaults or later overlay are applied."
            editButton.title = "Edit Selected Init File…"
            editButton.toolTip = "Open the exact custom init file selected above."
        }

        let validationError = custom ? customPathValidationError() : nil
        validationLabel.stringValue = validationError ?? ""
        validationLabel.isHidden = validationError == nil
        relaunchButton.isEnabled = validationError == nil
        editButton.isEnabled = validationError == nil
    }

    private func customPathValidationError() -> String? {
        let path = customPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "Choose a custom init file before relaunching." }
        guard NSString(string: path).isAbsolutePath else {
            return "The custom init path must be absolute."
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard NvimLaunchPlan.liveFileValidator(url) else {
            return "This file is missing, unreadable, or not a regular file."
        }
        return nil
    }

    @objc private func modeChanged() {
        persistValues()
        updateControls()
    }

    @objc private func pathEdited() {
        persistValues()
        updateControls()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        pathEdited()
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK, let url = panel.url {
            customPathField.stringValue = url.standardizedFileURL.path
            pathEdited()
        }
    }

    @objc private func editConfiguration() {
        persistValues()
        guard customPathValidationError() == nil || selection.mode != .custom else { return }

        onEditConfiguration?(selection)
        window?.close()
    }

    @objc private func relaunch() {
        persistValues()
        updateControls()
        guard relaunchButton.isEnabled else { return }
        onRelaunch?()
    }
}
