// Superlemon entry point — minimal NSApplication bootstrap (DESIGN.md §10).
// `--smoke` runs headless: session → attach → first flush → "SMOKE OK" → quit.

import AppKit

let smokeMode = CommandLine.arguments.contains("--smoke")

let app = NSApplication.shared
let delegate = AppDelegate(smokeMode: smokeMode)
app.delegate = delegate
app.setActivationPolicy(smokeMode ? .prohibited : .regular)
app.run()
