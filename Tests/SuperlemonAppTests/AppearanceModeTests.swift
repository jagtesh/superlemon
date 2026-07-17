// Appearance preference resolution and its end-to-end application: the GUI
// reports 'background' to the session (the UI-detection role
// `:h 'background'` describes), and the runtime module applies it.

import Foundation
import NvimKit
import Testing

@testable import EditorHostKit

private let appearanceNvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var appearanceNvimAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: appearanceNvimPath)
}

@Suite struct AppearanceModeTests {
    @Test func autoReportsTheSystemAppearanceWithoutForce() {
        #expect(AppearanceMode.auto.resolvedBackground(systemIsDark: true)
            == ("dark", false))
        #expect(AppearanceMode.auto.resolvedBackground(systemIsDark: false)
            == ("light", false))
    }

    @Test func lightAndDarkForceTheirValueRegardlessOfSystem() {
        #expect(AppearanceMode.light.resolvedBackground(systemIsDark: true)
            == ("light", true))
        #expect(AppearanceMode.dark.resolvedBackground(systemIsDark: false)
            == ("dark", true))
    }

    @Test func preferencesDefaultToAutoAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "appearance-tests-\(UUID().uuidString)")!
        #expect(AppearancePreferences.load(from: defaults) == .auto)
        AppearancePreferences.save(.dark, to: defaults)
        #expect(AppearancePreferences.load(from: defaults) == .dark)
        defaults.set("nonsense", forKey: "AppearanceMode")
        #expect(AppearancePreferences.load(from: defaults) == .auto)
    }

    @Test(
        "a reported background reaches a live session's option and colors",
        .enabled(if: appearanceNvimAvailable, "nvim not found at \(appearanceNvimPath)"),
        .timeLimit(.minutes(1)))
    func reportedBackgroundAppliesToLiveSession() async throws {
        let runtime = try #require(NvimController.runtimeDirectory())
        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: appearanceNvimPath),
            arguments: [
                "--embed", "--clean", "-i", "NONE",
                "--cmd", "set runtimepath^=\(runtime.path)",
            ]))
        try await session.start()
        _ = try await session.handshake()
        let consumer = Task {
            for await _ in session.uiEvents { if Task.isCancelled { return } }
        }
        defer { consumer.cancel() }
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        // The managed colorscheme adapts to 'background', so an auto report
        // takes effect end to end.
        let report = AppearanceMode.auto.resolvedBackground(systemIsDark: false)
        let applied = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    "local value, force = ...\n"
                        + "vim.cmd.colorscheme('default')\n"
                        + "local ok = require('superlemon.appearance').apply(value, force)\n"
                        + "return { ok = ok, bg = vim.o.background }"),
                .array([.string(report.value), .bool(report.force)]),
            ],
            timeout: .seconds(5))
        #expect(applied["ok"]?.boolValue == true)
        #expect(applied["bg"]?.stringValue == "light")

        // A colorscheme that pins 'background' (habamax sets it to dark) is
        // an explicit choice: the auto report backs off and the pin stands.
        let pinned = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    "vim.cmd.colorscheme('habamax')\n"
                        + "local ok = require('superlemon.appearance').apply('light', false)\n"
                        + "return { ok = ok, bg = vim.o.background }"),
                .array([]),
            ],
            timeout: .seconds(5))
        #expect(pinned["ok"]?.boolValue == false)
        #expect(pinned["bg"]?.stringValue == "dark")

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }
}
