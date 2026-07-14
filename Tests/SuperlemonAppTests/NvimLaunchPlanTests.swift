import AppKit
import Foundation
import NvimKit
import Testing

@testable import EditorHostKit

private let startupSafetyNvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var startupSafetyNvimAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: startupSafetyNvimPath)
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

@Suite("Neovim configuration launch planning", .serialized)
struct NvimLaunchPlanTests {
    private let executableURL = URL(fileURLWithPath: "/Applications/Superlemon.app/nvim")
    private let runtimeURL = URL(fileURLWithPath: "/Applications/Superlemon.app/runtime")

    private func makePlan(
        selection: NvimConfigSelection,
        environment: [String: String] = [:],
        safeStart: Bool = false,
        readable: @escaping (URL) -> Bool = { _ in true },
        executable: @escaping (URL) -> Bool = { _ in true }
    ) throws -> NvimLaunchPlan {
        try NvimLaunchPlan.make(
            selection: selection,
            executableURL: executableURL,
            runtimeURL: runtimeURL,
            baseEnvironment: environment,
            safeStart: safeStart,
            isReadableRegularFile: readable,
            isExecutableFile: executable)
    }

    private func makeHangingExecutable(in directory: URL, marker: URL? = nil) throws -> URL {
        let executable = directory.appendingPathComponent("hanging-nvim")
        var script = "#!/bin/sh\n"
        if let marker { script += "/usr/bin/touch '\(marker.path)'\n" }
        script += "trap 'exit 0' TERM INT\nwhile :; do /bin/sleep 1; done\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Keeps the real-Neovim lifecycle test out of the developer's HOME and
    /// disables shada persistence while preserving NvimController's exact
    /// launch arguments and embedded startup behavior.
    private func makeIsolatedNvimWrapper(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("isolated-nvim")
        let state = directory.appendingPathComponent("xdg", isDirectory: true)
        for component in ["home", "config", "data", "state", "cache"] {
            try FileManager.default.createDirectory(
                at: state.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let script = """
            #!/bin/sh
            export HOME=\(shellQuote(state.appendingPathComponent("home").path))
            export XDG_CONFIG_HOME=\(shellQuote(state.appendingPathComponent("config").path))
            export XDG_DATA_HOME=\(shellQuote(state.appendingPathComponent("data").path))
            export XDG_STATE_HOME=\(shellQuote(state.appendingPathComponent("state").path))
            export XDG_CACHE_HOME=\(shellQuote(state.appendingPathComponent("cache").path))
            exec \(shellQuote(startupSafetyNvimPath)) "$@" -i NONE
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("legacy custom path wins migration even when it has gone missing")
    func legacyCustomMigration() {
        let selection = NvimConfigPreferences.migratedSelection(
            modeRawValue: nil,
            legacyManaged: true,
            customInitPath: nil,
            legacyCustomInitPath: "/missing/custom.lua")
        #expect(selection == NvimConfigSelection(
            mode: .custom, customInitPath: "/missing/custom.lua"))
    }

    @Test("legacy managed checkbox maps to mutually exclusive modes", arguments: [
        (true, NvimConfigMode.managed),
        (false, NvimConfigMode.user),
    ])
    func legacyManagedMigration(value: Bool, expected: NvimConfigMode) {
        let selection = NvimConfigPreferences.migratedSelection(
            modeRawValue: nil,
            legacyManaged: value,
            customInitPath: nil,
            legacyCustomInitPath: nil)
        #expect(selection.mode == expected)
    }

    @Test("new mode remains authoritative while retaining the custom path")
    func currentModeWinsMigration() {
        let selection = NvimConfigPreferences.migratedSelection(
            modeRawValue: NvimConfigMode.user.rawValue,
            legacyManaged: true,
            customInitPath: "/tmp/remembered.lua",
            legacyCustomInitPath: "/tmp/legacy.lua")
        #expect(selection == NvimConfigSelection(
            mode: .user, customInitPath: "/tmp/remembered.lua"))
    }

    @Test("managed mode selects only the bundled init")
    func managedPlan() throws {
        let plan = try makePlan(
            selection: NvimConfigSelection(mode: .managed, customInitPath: nil))
        #expect(plan.executableURL == executableURL)
        #expect(plan.runtimeURL == runtimeURL)
        #expect(plan.configURL == runtimeURL.appendingPathComponent("config/init.lua"))
        #expect(plan.arguments == [
            "--embed",
            "--cmd", "lua vim.opt.runtimepath:prepend(vim.env.SUPERLEMON_RUNTIME)",
            "-u", runtimeURL.appendingPathComponent("config/init.lua").path,
        ])
        #expect(plan.environment["SUPERLEMON_RUNTIME"] == runtimeURL.path)
        #expect(plan.environment["NVIM_APPNAME"] == "superlemon")
        #expect(plan.environment["SUPERLEMON_SAFE_START"] == nil)
    }

    @Test("user mode adds no init arguments or managed overlay")
    func userPlan() throws {
        let plan = try makePlan(
            selection: NvimConfigSelection(
                mode: .user, customInitPath: "/tmp/remembered.lua"),
            environment: ["NVIM_APPNAME": "my-profile"])
        #expect(plan.configURL == nil)
        #expect(plan.arguments == [
            "--embed",
            "--cmd", "lua vim.opt.runtimepath:prepend(vim.env.SUPERLEMON_RUNTIME)",
        ])
        #expect(plan.environment["NVIM_APPNAME"] == "my-profile")
    }

    @Test("custom mode selects the exact standardized path")
    func customPlan() throws {
        let plan = try makePlan(
            selection: NvimConfigSelection(mode: .custom, customInitPath: "/tmp/a/../init.lua"),
            environment: ["SUPERLEMON_LISTEN": "/tmp/superlemon.sock"])
        #expect(plan.arguments == [
            "--embed",
            "--cmd", "lua vim.opt.runtimepath:prepend(vim.env.SUPERLEMON_RUNTIME)",
            "--listen", "/tmp/superlemon.sock",
            "-u", runtimeURL.appendingPathComponent("config/custom-init.lua").path,
        ])
        #expect(plan.configURL?.path == "/tmp/init.lua")
        #expect(plan.environment["SUPERLEMON_CUSTOM_INIT"] == "/tmp/init.lua")
    }

    @Test("custom mode never silently falls back", arguments: [
        (nil, NvimLaunchPlan.PlanError.missingCustomInitPath),
        ("relative/init.lua", NvimLaunchPlan.PlanError.customInitPathMustBeAbsolute(
            "relative/init.lua")),
        ("/missing/init.lua", NvimLaunchPlan.PlanError.unreadableCustomInit(
            "/missing/init.lua")),
    ])
    func invalidCustomPath(path: String?, expected: NvimLaunchPlan.PlanError) {
        #expect(throws: expected) {
            try makePlan(
                selection: NvimConfigSelection(mode: .custom, customInitPath: path),
                readable: { url in
                    url.path.hasSuffix("lua/superlemon/init.lua")
                })
        }
    }

    @Test("safe start is isolated and explicit")
    func safeStartPlan() throws {
        let plan = try makePlan(
            selection: NvimConfigSelection(mode: .managed, customInitPath: nil),
            environment: ["SUPERLEMON_SAFE_START": "stale"],
            safeStart: true)
        #expect(plan.safeStart)
        #expect(plan.environment["NVIM_APPNAME"] == "superlemon-safe")
        #expect(plan.environment["SUPERLEMON_SAFE_START"] == "1")
    }

    @Test("launch inputs fail before process creation")
    func launchInputValidation() {
        #expect(throws: NvimLaunchPlan.PlanError.executableUnavailable(executableURL.path)) {
            try makePlan(
                selection: NvimConfigSelection(mode: .managed, customInitPath: nil),
                executable: { _ in false })
        }
        #expect(throws: NvimLaunchPlan.PlanError.runtimeUnavailable(runtimeURL.path)) {
            try makePlan(
                selection: NvimConfigSelection(mode: .managed, customInitPath: nil),
                readable: { _ in false })
        }
    }

    @Test("ordinary user init resolution ignores the managed session profile")
    func userInitResolutionFromBaseEnvironment() {
        let environment = [
            "HOME": "/Users/example",
            "XDG_CONFIG_HOME": "/Users/example/config",
        ]
        let resolved = NvimLaunchPlan.preferredUserInitURL(
            environment: environment,
            isRegularFile: { $0.path == "/Users/example/config/nvim/init.vim" })
        #expect(resolved.path == "/Users/example/config/nvim/init.vim")
    }

    @Test("explicit user profile and MYVIMRC are honored")
    func userInitResolutionHonorsEnvironment() {
        let profiled = NvimLaunchPlan.preferredUserInitURL(
            environment: [
                "HOME": "/Users/example",
                "XDG_CONFIG_HOME": "/Users/example/config",
                "NVIM_APPNAME": "work-nvim",
            ],
            isRegularFile: { _ in false })
        #expect(profiled.path == "/Users/example/config/work-nvim/init.lua")

        let explicit = NvimLaunchPlan.preferredUserInitURL(
            environment: ["MYVIMRC": "~/dotfiles/init.lua", "HOME": "/ignored"],
            isRegularFile: { _ in false })
        #expect(explicit.path.hasSuffix("/dotfiles/init.lua"))
    }

    @Test("Neovim versions below 0.12 are rejected")
    func minimumNeovimVersion() {
        #expect(!NvimController.isSupportedNvimVersion("0.10.4"))
        #expect(NvimController.isSupportedNvimVersion("0.11.2"))
        #expect(NvimController.isSupportedNvimVersion("0.12.0"))
        #expect(NvimController.isSupportedNvimVersion("0.12.4-dev-10"))
        #expect(NvimController.isSupportedNvimVersion("1.0.0"))
        #expect(!NvimController.isSupportedNvimVersion("not-a-version"))
    }

    @Test("native menu state follows Neovim buffer and undo capabilities")
    func editorCommandState() {
        let visual = NvimController.EditorCommandState(payload: .map([
            (.string("file"), .string("src/main.swift")),
            (.string("mode"), .string("v")),
            (.string("modifiable"), .bool(true)),
            (.string("readonly"), .bool(false)),
            (.string("buftype"), .string("")),
            (.string("can_undo"), .bool(true)),
            (.string("can_redo"), .bool(false)),
        ]))
        #expect(visual.hasVisualSelection)
        #expect(visual.canWrite)
        #expect(visual.canUndo)
        #expect(!visual.canRedo)

        let special = NvimController.EditorCommandState(payload: .map([
            (.string("file"), .string("help.txt")),
            (.string("mode"), .string("n")),
            (.string("modifiable"), .bool(true)),
            (.string("readonly"), .bool(false)),
            (.string("buftype"), .string("nofile")),
        ]))
        #expect(!special.hasVisualSelection)
        #expect(!special.canWrite)

        let unnamed = NvimController.EditorCommandState(payload: .map([
            (.string("file"), .string("")),
            (.string("modifiable"), .bool(true)),
            (.string("readonly"), .bool(false)),
            (.string("buftype"), .string("")),
        ]))
        #expect(!unnamed.canWrite)
        #expect(NvimController.beginFindInput == "<C-\\><C-N><Esc>/")
    }

    @Test("lifecycle generations reject stale callbacks")
    func lifecycleGenerationFence() {
        var lifecycle = NvimController.LifecycleState()
        let first = lifecycle.beginGeneration()
        lifecycle.phase = .running
        #expect(lifecycle.accepts(generation: first))

        let replacement = lifecycle.beginGeneration()
        lifecycle.phase = .starting
        #expect(!lifecycle.accepts(generation: first))
        #expect(lifecycle.accepts(generation: replacement))
        #expect(lifecycle.phase == .starting)
    }

    @Test("relaunch intent is cancelled or consumed exactly once")
    func relaunchIntentOwnership() throws {
        var launches = 0
        var cancelled = NvimController.TerminationIntentStore()
        cancelled.requestRelaunch { launches += 1 }
        let didCancel = cancelled.cancel()
        let cancelledIntent = cancelled.take()
        #expect(didCancel)
        #expect(cancelledIntent == nil)
        #expect(launches == 0)

        var approved = NvimController.TerminationIntentStore()
        approved.requestRelaunch { launches += 1 }
        approved.requestQuitIfNeeded()  // must not replace the relaunch
        guard case .relaunch(let action) = approved.take() else {
            Issue.record("approved relaunch intent was lost")
            return
        }
        try action()
        let secondTake = approved.take()
        #expect(secondTake == nil)
        #expect(launches == 1)
    }

    @Test("stopping while binary resolution is suspended cannot spawn Neovim")
    @MainActor
    func preSessionStopInvalidatesStartupGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-start-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("started")
        let executable = try makeHangingExecutable(in: root, marker: marker)
        let entered = AsyncGate()
        let release = AsyncGate()
        let controller = NvimController(
            nvimBinaryResolver: {
                await entered.open()
                await release.wait()
                return executable
            },
            configSelectionProvider: {
                NvimConfigSelection(mode: .managed, customInitPath: nil)
            })

        let startup = Task { await controller.start() }
        await entered.wait()
        controller.stop()
        await release.open()
        await startup.value
        try? await Task.sleep(for: .milliseconds(50))

        #expect(controller.session == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(
        "quit during failed real Neovim startup protects a modified buffer",
        .enabled(if: startupSafetyNvimAvailable, "nvim not found at \(startupSafetyNvimPath)"),
        .timeLimit(.minutes(1)))
    @MainActor
    func quitDuringStartupInspectsModifiedRealNvimBuffer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-startup-data-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = root.appendingPathComponent("unsaved-startup.txt")
        let ready = root.appendingPathComponent("config-created-modified-buffer")
        let release = root.appendingPathComponent("allow-config-to-fail")
        let customInit = root.appendingPathComponent("init.lua")
        let script = """
            local document = [=[\(document.path)]=]
            local ready = [=[\(ready.path)]=]
            local release = [=[\(release.path)]=]
            vim.o.shada = ''
            vim.o.loadplugins = false
            vim.api.nvim_create_autocmd('VimEnter', {
              once = true,
              callback = function()
                local buffer = vim.api.nvim_get_current_buf()
                vim.api.nvim_buf_set_name(buffer, document)
                vim.api.nvim_buf_set_lines(
                  buffer, 0, -1, false, { 'startup edit must survive' })
                vim.bo[buffer].modified = true
                vim.fn.writefile({ 'ready' }, ready)
                local deadline = vim.uv.hrtime() + 10000000000
                while vim.uv.fs_stat(release) == nil do
                  assert(vim.uv.hrtime() < deadline, 'test did not release startup')
                  vim.uv.sleep(10)
                end
              end,
            })
            error('startup-failure-marker')
            """
        try script.write(to: customInit, atomically: true, encoding: .utf8)
        let nvim = try makeIsolatedNvimWrapper(in: root)
        let controller = NvimController(
            nvimBinaryResolver: { nvim },
            configSelectionProvider: {
                NvimConfigSelection(mode: .custom, customInitPath: customInit.path)
            })
        var startupFailure: String?
        var terminationReplies: [Bool] = []
        controller.startupFailureHandler = { startupFailure = $0 }
        controller.replyToApplicationTermination = { terminationReplies.append($0) }
        defer { controller.stop() }

        let startup = Task { await controller.start() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: ready.path) })
        #expect(startupFailure == nil)
        guard controller.session != nil else {
            Issue.record("Neovim exited before the startup quit could be queued")
            return
        }

        #expect(controller.handleTerminationRequest() == .terminateLater)
        try "release\n".write(to: release, atomically: true, encoding: .utf8)
        await startup.value
        #expect(await waitUntil { controller.editorCommandsAvailable })
        #expect(terminationReplies == [false])
        #expect(startupFailure == nil)
        let session = try #require(controller.session)
        let state = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    """
                    local path = ...
                    local target = vim.fn.resolve(path)
                    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
                      if vim.fn.resolve(vim.api.nvim_buf_get_name(buffer)) == target then
                        return {
                          modified = vim.bo[buffer].modified,
                          line = vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1],
                        }
                      end
                    end
                    return {}
                    """),
                .array([.string(document.path)]),
            ],
            timeout: .seconds(5))

        #expect(state["modified"]?.boolValue == true)
        #expect(state["line"]?.stringValue == "startup edit must survive")
        #expect(!FileManager.default.fileExists(atPath: document.path))
    }

    @Test("relaunch during startup reaps Neovim and resolves AppKit once")
    @MainActor
    func relaunchDuringStartupIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-start-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeHangingExecutable(in: root)
        let controller = NvimController(
            nvimBinaryResolver: { executable },
            configSelectionProvider: {
                NvimConfigSelection(mode: .managed, customInitPath: nil)
            })
        var startupFailure: String?
        controller.startupFailureHandler = { startupFailure = $0 }
        var initialReply: NSApplication.TerminateReply?
        var replies: [Bool] = []
        var replacementLaunches = 0
        controller.replyToApplicationTermination = { replies.append($0) }
        controller.requestApplicationTermination = {
            initialReply = controller.handleTerminationRequest()
        }

        let startup = Task { await controller.start() }
        #expect(await waitUntil { controller.session != nil || startupFailure != nil })
        #expect(startupFailure == nil)
        guard controller.session != nil else { return }
        controller.requestRelaunch { replacementLaunches += 1 }
        #expect(initialReply == .terminateLater)
        #expect(await waitUntil(timeout: .seconds(15)) { !replies.isEmpty })
        await startup.value

        // The child is alive but has no usable RPC stream. Headless tests
        // cannot present the Cancel / Force Quit alert, so the safe fallback
        // is Cancel: do not reap it, discard data, or launch a replacement.
        #expect(replies == [false])
        #expect(replacementLaunches == 0)
        #expect(controller.session != nil)
        controller.stop()
    }

    @Test("quit during startup reaps Neovim and resolves AppKit once")
    @MainActor
    func quitDuringStartupIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-start-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeHangingExecutable(in: root)
        let controller = NvimController(
            nvimBinaryResolver: { executable },
            configSelectionProvider: {
                NvimConfigSelection(mode: .managed, customInitPath: nil)
            })
        var startupFailure: String?
        var replies: [Bool] = []
        controller.startupFailureHandler = { startupFailure = $0 }
        controller.replyToApplicationTermination = { replies.append($0) }

        let startup = Task { await controller.start() }
        #expect(await waitUntil { controller.session != nil || startupFailure != nil })
        #expect(startupFailure == nil)
        guard controller.session != nil else { return }
        #expect(controller.handleTerminationRequest() == .terminateLater)
        #expect(await waitUntil(timeout: .seconds(15)) { !replies.isEmpty })
        await startup.value

        #expect(replies == [false])
        #expect(controller.session != nil)
        controller.stop()
    }
}
