// Superlemon entry point — minimal NSApplication bootstrap (DESIGN.md §10).
// `--smoke` runs headless: session → attach → first flush → "SMOKE OK" → quit.

import AppKit

let smokeMode = CommandLine.arguments.contains("--smoke")

// Superlemon's managed config is the DEFAULT experience; Settings can instead
// select the user's normal Neovim init or an explicit init file.
// register(defaults:) only applies when the user hasn't chosen explicitly.
// Key repeat, not the accent picker: holding j/k must repeat like a
// terminal. Written to the app's own domain (register() can't beat the
// global domain's true).
UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

UserDefaults.standard.register(defaults: [
    NvimController.managedConfigDefaultsKey: true
])

// Register bundled symbol fonts (runtime/fonts/, e.g. Fira Code under its
// OFL license) for THIS PROCESS only — no system install. The renderer's
// symbol-companion resolution then finds them by name.
if let fontsDir = NvimController.runtimeDirectory()?.appendingPathComponent("fonts"),
    let files = try? FileManager.default.contentsOfDirectory(
        at: fontsDir, includingPropertiesForKeys: nil)
{
    for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
}

let app = NSApplication.shared
// A packaged .app gets its icon from the compiled asset catalog so macOS can
// apply the current system mask and material. The resource-bundle icon is only
// a fallback for launching the bare SwiftPM executable during development.
if Bundle.main.bundleURL.pathExtension != "app",
    let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
    let icon = NSImage(contentsOf: iconURL)
{
    app.applicationIconImage = icon
}
let delegate = AppDelegate(smokeMode: smokeMode)
app.delegate = delegate
app.setActivationPolicy(smokeMode ? .prohibited : .regular)
app.run()
