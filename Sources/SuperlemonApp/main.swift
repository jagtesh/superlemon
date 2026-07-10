// Superlemon entry point — minimal NSApplication bootstrap (DESIGN.md §10).
// `--smoke` runs headless: session → attach → first flush → "SMOKE OK" → quit.

import AppKit

let smokeMode = CommandLine.arguments.contains("--smoke")

// Superlemon's managed config is the DEFAULT experience; the app menu's
// "Use Superlemon Config" checkbox switches to the user's own init.
// register(defaults:) only applies when the user hasn't chosen explicitly.
UserDefaults.standard.register(defaults: [
    NvimController.managedConfigDefaultsKey: true
])

let app = NSApplication.shared
let delegate = AppDelegate(smokeMode: smokeMode)
app.delegate = delegate
app.setActivationPolicy(smokeMode ? .prohibited : .regular)
app.run()
