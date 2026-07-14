import Foundation
import NvimKit
import Testing

@testable import EditorHostKit

@Suite("Workspace chrome safety")
struct WorkspaceChromeTests {
    @Test("Quick Open revalidates the selected file inside the active workspace")
    func validatesQuickOpenSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-quick-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("present.swift")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let resolved = try WorkspaceChrome.validatedQuickOpenURL(
            relativePath: "present.swift", projectRoot: root)
        #expect(resolved == file.standardizedFileURL)

        #expect(throws: QuickOpenSelectionError.notAFile(
            root.appendingPathComponent("deleted.swift").path)
        ) {
            try WorkspaceChrome.validatedQuickOpenURL(
                relativePath: "deleted.swift", projectRoot: root)
        }

        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: QuickOpenSelectionError.notAFile(folder.path)) {
            try WorkspaceChrome.validatedQuickOpenURL(
                relativePath: "folder", projectRoot: root)
        }

        let escaped = root.deletingLastPathComponent().appendingPathComponent("outside.swift")
        #expect(throws: QuickOpenSelectionError.outsideWorkspace(escaped.path)) {
            try WorkspaceChrome.validatedQuickOpenURL(
                relativePath: "../outside.swift", projectRoot: root)
        }
    }

    @Test("Remote selections keep containment checks without a local stat")
    func containsQuickOpenSelectionWithoutLocalFilesystem() throws {
        // The root deliberately does not exist on this machine: containment
        // is pure path logic, valid for a remote session's filesystem.
        let root = URL(fileURLWithPath: "/remote/workspace", isDirectory: true)

        let resolved = try WorkspaceChrome.containedQuickOpenURL(
            relativePath: "Sources/app.swift", projectRoot: root)
        #expect(resolved.path == "/remote/workspace/Sources/app.swift")

        #expect(throws: QuickOpenSelectionError.outsideWorkspace("/remote/outside.swift")) {
            try WorkspaceChrome.containedQuickOpenURL(
                relativePath: "../outside.swift", projectRoot: root)
        }
    }

    @Test("superlemon.chrome parses native_sidebar with a visible default")
    @MainActor
    func chromeNotificationParsesNativeSidebar() {
        // WorkspaceChrome references its controller unowned; keep it alive
        // for the whole test.
        let controller = NvimController()
        let chrome = WorkspaceChrome(
            controller: controller,
            projectRoot: FileManager.default.temporaryDirectory)
        var observedSidebar: [Bool] = []
        chrome.onChromeModeChange = { _, _, _, _, nativeSidebar in
            observedSidebar.append(nativeSidebar)
        }

        chrome.handleNotification(
            "superlemon.chrome",
            [.map([
                (.string("native_tabs"), .bool(true)),
                (.string("native_sidebar"), .bool(false)),
            ])])
        #expect(chrome.nativeSidebar == false)

        // A payload without the key (older runtime) keeps the sidebar on.
        chrome.handleNotification(
            "superlemon.chrome", [.map([(.string("native_tabs"), .bool(true))])])
        #expect(chrome.nativeSidebar == true)
        #expect(observedSidebar == [false, true])
        withExtendedLifetime(controller) {}
    }

    @Test("superlemon.cwd re-roots the workspace only when the path changes")
    @MainActor
    func cwdNotificationReRootsOnChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-cwd-\(UUID().uuidString)", isDirectory: true)
        let other = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = NvimController()
        let chrome = WorkspaceChrome(controller: controller, projectRoot: root)

        chrome.handleNotification(
            "superlemon.cwd", [.map([(.string("cwd"), .string(other.path))])])
        #expect(chrome.projectRoot.path == other.standardizedFileURL.path)

        // A same-path echo (GUI-initiated cd already re-rooted) is a no-op:
        // the quick-open index is not rebuilt.
        let indexBefore = chrome.fileIndex
        chrome.handleNotification(
            "superlemon.cwd", [.map([(.string("cwd"), .string(other.path))])])
        #expect(chrome.fileIndex === indexBefore)

        // Malformed payloads leave the workspace alone.
        chrome.handleNotification("superlemon.cwd", [.map([])])
        chrome.handleNotification(
            "superlemon.cwd", [.map([(.string("cwd"), .string(""))])])
        #expect(chrome.projectRoot.path == other.standardizedFileURL.path)
        withExtendedLifetime(controller) {}
    }

    @Test("hasRemoteFilesystem follows the host-supplied launch configuration")
    @MainActor
    func remoteFilesystemFlag() {
        #expect(!NvimController().hasRemoteFilesystem)

        let bridge = NvimLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: ["-U", "/tmp/nvim.sock"])
        #expect(NvimController(launchConfiguration: bridge).hasRemoteFilesystem)
        #expect(
            !NvimController(launchConfiguration: bridge, remoteFilesystem: false)
                .hasRemoteFilesystem)
    }
}
