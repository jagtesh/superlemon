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
