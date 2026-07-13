import Foundation
import NvimKit
import Testing

@testable import SuperlemonApp

private let quitTestNvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var quitTestNvimAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: quitTestNvimPath)
}

@Suite("Quit data safety", .serialized)
struct QuitSafetyTests {
    @Test(
        "custom mode executes exactly the selected init once with no managed overlay",
        .enabled(if: quitTestNvimAvailable, "nvim not found at \(quitTestNvimPath)"),
        .timeLimit(.minutes(1)))
    func customConfigurationExecutesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-custom-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let customInit = root.appendingPathComponent("init.lua")
        try "vim.g.custom_init_probe = (vim.g.custom_init_probe or 0) + 1\nvim.opt.number = true\n"
            .write(to: customInit, atomically: true, encoding: .utf8)

        let runtime = try #require(NvimController.runtimeDirectory())
        let plan = try NvimLaunchPlan.make(
            selection: NvimConfigSelection(mode: .custom, customInitPath: customInit.path),
            executableURL: URL(fileURLWithPath: quitTestNvimPath),
            runtimeURL: runtime,
            baseEnvironment: ProcessInfo.processInfo.environment)
        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: plan.executableURL,
            arguments: plan.arguments + ["-i", "NONE"],
            environment: plan.environment))
        try await session.start()
        _ = try await session.handshake()
        let redrawConsumer = Task {
            for await _ in session.uiEvents {
                if Task.isCancelled { return }
            }
        }
        defer { redrawConsumer.cancel() }
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        try await NvimController.validateCustomConfiguration(session, path: customInit.path)
        try await NvimController.validateCustomConfiguration(session, path: customInit.path)
        let state = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    "return { count = vim.g.custom_init_probe, number = vim.o.number, managed = vim.g.superlemon_native_tabs }"),
                .array([]),
            ],
            timeout: .seconds(5))
        #expect(state["count"]?.intValue == 1)
        #expect(state["number"]?.boolValue == true)
        #expect(state["managed"] == nil)

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }

    @Test(
        "custom Vimscript is sourced exactly once by the diagnostic loader",
        .enabled(if: quitTestNvimAvailable, "nvim not found at \(quitTestNvimPath)"),
        .timeLimit(.minutes(1)))
    func customVimscriptExecutesExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-custom-vim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let customInit = root.appendingPathComponent("init.vim")
        try "let g:custom_vim_probe = get(g:, 'custom_vim_probe', 0) + 1\nset number\n"
            .write(to: customInit, atomically: true, encoding: .utf8)

        let runtime = try #require(NvimController.runtimeDirectory())
        let plan = try NvimLaunchPlan.make(
            selection: NvimConfigSelection(mode: .custom, customInitPath: customInit.path),
            executableURL: URL(fileURLWithPath: quitTestNvimPath),
            runtimeURL: runtime,
            baseEnvironment: ProcessInfo.processInfo.environment)
        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: plan.executableURL,
            arguments: plan.arguments + ["-i", "NONE"],
            environment: plan.environment))
        try await session.start()
        _ = try await session.handshake()
        let redrawConsumer = Task {
            for await _ in session.uiEvents {
                if Task.isCancelled { return }
            }
        }
        defer { redrawConsumer.cancel() }
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        try await NvimController.validateCustomConfiguration(session, path: customInit.path)
        try await NvimController.validateCustomConfiguration(session, path: customInit.path)
        let state = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    "return { count = vim.g.custom_vim_probe, number = vim.o.number, managed = vim.g.superlemon_native_tabs }"),
                .array([]),
            ],
            timeout: .seconds(5))
        #expect(state["count"]?.intValue == 1)
        #expect(state["number"]?.boolValue == true)
        #expect(state["managed"] == nil)

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }

    @Test(
        "a broken custom init is promoted to a visible startup failure",
        .enabled(if: quitTestNvimAvailable, "nvim not found at \(quitTestNvimPath)"),
        .timeLimit(.minutes(1)))
    func brokenCustomConfigurationIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let customInit = root.appendingPathComponent("init.lua")
        try "vim.g.custom_init_probe = 123\nerror('custom-init-marker')\n".write(
            to: customInit, atomically: true, encoding: .utf8)

        let runtime = try #require(NvimController.runtimeDirectory())
        let plan = try NvimLaunchPlan.make(
            selection: NvimConfigSelection(mode: .custom, customInitPath: customInit.path),
            executableURL: URL(fileURLWithPath: quitTestNvimPath),
            runtimeURL: runtime,
            baseEnvironment: ProcessInfo.processInfo.environment)
        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: plan.executableURL,
            arguments: plan.arguments + ["-i", "NONE"],
            environment: plan.environment))
        try await session.start()
        _ = try await session.handshake()
        let redrawConsumer = Task {
            for await _ in session.uiEvents {
                if Task.isCancelled { return }
            }
        }
        defer { redrawConsumer.cancel() }
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        do {
            try await NvimController.validateCustomConfiguration(
                session, path: customInit.path)
            Issue.record("broken custom init was accepted")
        } catch {
            #expect(error.localizedDescription.contains(customInit.path))
            #expect(error.localizedDescription.contains("custom-init-marker"))
        }

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }

    @Test(
        "all loaded modified buffer classes are protected and saved independently",
        .enabled(if: quitTestNvimAvailable, "nvim not found at \(quitTestNvimPath)"),
        .timeLimit(.minutes(1)))
    func modifiedBufferCoverageAndLateEditProtection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: quitTestNvimPath),
            arguments: ["--embed", "--clean", "-u", "NONE", "-i", "NONE"]))
        try await session.start()
        _ = try await session.handshake()
        let redrawConsumer = Task {
            for await _ in session.uiEvents {
                if Task.isCancelled { return }
            }
        }
        defer { redrawConsumer.cancel() }
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        let fixture = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    """
                    local root = ...
                    local result = {}
                    local function fill(b, text)
                      vim.api.nvim_buf_set_lines(b, 0, -1, false, { text })
                      vim.bo[b].modified = true
                      return b
                    end

                    local named = vim.api.nvim_get_current_buf()
                    vim.api.nvim_buf_set_name(named, root .. '/named.txt')
                    result.named = fill(named, 'named')

                    local unnamed = vim.api.nvim_create_buf(true, false)
                    result.unnamed = fill(unnamed, 'unnamed')

                    local unlisted = vim.api.nvim_create_buf(false, false)
                    vim.api.nvim_buf_set_name(unlisted, root .. '/unlisted.txt')
                    result.unlisted = fill(unlisted, 'unlisted')

                    local special = vim.api.nvim_create_buf(true, false)
                    -- acwrite is a special buffer that can remain modified but
                    -- refuses :write unless a provider installs BufWriteCmd.
                    vim.bo[special].buftype = 'acwrite'
                    result.special = fill(special, 'special')

                    local readonly = vim.api.nvim_create_buf(true, false)
                    vim.api.nvim_buf_set_name(readonly, root .. '/readonly.txt')
                    fill(readonly, 'readonly')
                    vim.bo[readonly].readonly = true
                    result.readonly = readonly
                    return result
                    """),
                .array([.string(root.path)]),
            ],
            timeout: .seconds(5))

        let expectedHandles = Set([
            fixture["named"]?.intValue,
            fixture["unnamed"]?.intValue,
            fixture["unlisted"]?.intValue,
            fixture["special"]?.intValue,
            fixture["readonly"]?.intValue,
        ].compactMap { $0 })
        #expect(expectedHandles.count == 5)

        let inspected = try await NvimController.queryModifiedBuffers(session)
        #expect(Set(inspected.map(\.handle)) == expectedHandles)
        #expect(inspected.contains { !$0.listed })
        #expect(inspected.contains { $0.name.isEmpty })
        #expect(inspected.contains { $0.bufferType == "acwrite" })
        #expect(inspected.contains { $0.readOnly })

        let failures = try await NvimController.writeModifiedBuffers(session)
        #expect(failures.count == 3)
        #expect(failures.contains { $0.displayName.contains("No Name") })
        #expect(failures.contains { $0.displayName.contains("acwrite") })
        #expect(failures.contains { $0.displayName.contains("readonly") })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("named.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unlisted.txt").path))

        let remaining = try await NvimController.queryModifiedBuffers(session)
        #expect(remaining.count == 3)

        // Prove the clean branch must use no-bang qa: after an empty probe, a
        // new edit makes qa reject rather than discarding the late change.
        _ = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    """
                    for _, b in ipairs(vim.api.nvim_list_bufs()) do
                      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
                        vim.bo[b].readonly = false
                        vim.bo[b].modified = false
                      end
                    end
                    """),
                .array([]),
            ],
            timeout: .seconds(5))
        #expect(try await NvimController.queryModifiedBuffers(session).isEmpty)

        _ = try await session.request(
            "nvim_exec_lua",
            [
                .string("vim.bo[vim.api.nvim_get_current_buf()].modified = true"),
                .array([]),
            ],
            timeout: .seconds(5))
        do {
            _ = try await session.request(
                "nvim_command", [.string("qa")], timeout: .seconds(2))
            Issue.record("clean qa unexpectedly discarded a late modification")
        } catch NvimError.rpc(_, let message) {
            #expect(message.contains("No write since last change"))
        }

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }
}
