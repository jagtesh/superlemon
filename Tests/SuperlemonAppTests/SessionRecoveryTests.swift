import AppKit
import Foundation
import NvimKit
import Testing
@testable import EditorHostKit

@Suite("Local Neovim crash recovery", .serialized)
struct SessionRecoveryTests {
    @Test("SIGKILL restores unsaved named and unnamed buffers, splits and cursor", .timeLimit(.minutes(1)))
    @MainActor
    func killedChildRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "disk original\n".write(to: file, atomically: true, encoding: .utf8)
        let runtime = try #require(NvimController.runtimeDirectory())
        let configuration = NvimLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"),
            arguments: ["--embed", "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set rtp^=\(runtime.path)"],
            environment: ProcessInfo.processInfo.environment)
        let controller = NvimController(launchConfiguration: configuration, remoteFilesystem: false, configMode: .user)
        var failure: String?
        controller.startupFailureHandler = { failure = $0 }
        defer { controller.stop() }
        await controller.start()
        #expect(failure == nil)
        let original = try #require(controller.session)
        _ = try await original.request("nvim_exec_lua", [.string("""
            vim.cmd.edit(vim.fn.fnameescape(...))
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'unsaved one', 'unsaved two'})
            vim.cmd('vnew')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'scratch one', 'scratch two'})
            vim.api.nvim_win_set_cursor(0, {2, 3})
            vim.api.nvim_exec_autocmds('CursorMoved', {})
            """), .array([.string(file.path)])])
        // Allow the scheduled workspace notification to reach the host.
        for _ in 0..<100 {
            if controller.recovery.buffers.values.contains(where: { $0["lines"]?.arrayValue?.first?.stringValue == "scratch one" }),
               controller.recovery.workspace != .nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        original.forceKillNow()
        for _ in 0..<500 {
            if let current = controller.session, current !== original, controller.editorCommandsAvailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failure == nil)
        let recovered = try #require(controller.session)
        #expect(recovered !== original)
        #expect(controller.editorCommandsAvailable)
        let state = try await recovered.request("nvim_exec_lua", [.string("""
            local named = vim.fn.bufnr(...)
            return {named = vim.api.nvim_buf_get_lines(named, 0, -1, false),
              modified = vim.bo[named].modified,
              scratch = vim.api.nvim_buf_get_lines(0, 0, -1, false),
              cursor = vim.api.nvim_win_get_cursor(0), windows = #vim.tbl_filter(function(w) return vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" end, vim.api.nvim_tabpage_list_wins(0))}
            """), .array([.string(file.path)])])
        #expect(state["named"] == .array([.string("unsaved one"), .string("unsaved two")]))
        #expect(state["modified"]?.boolValue == true)
        #expect(state["scratch"] == .array([.string("scratch one"), .string("scratch two")]))
        #expect(state["cursor"] == .array([.int(2), .int(3)]))
        #expect(state["windows"]?.intValue == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == "disk original\n")
    }
}
