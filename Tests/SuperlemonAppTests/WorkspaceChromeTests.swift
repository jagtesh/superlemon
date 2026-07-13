import Foundation
import Testing

@testable import SuperlemonApp

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
}
