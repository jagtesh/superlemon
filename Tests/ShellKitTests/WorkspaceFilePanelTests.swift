import AppKit
import Foundation
import Testing

@testable import ShellKit

@MainActor
private func makeFixtureRoot() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("WorkspaceFilePanel-\(UUID().uuidString)")
    try fm.createDirectory(
        at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    fm.createFile(atPath: root.appendingPathComponent("README.md").path, contents: Data())
    fm.createFile(atPath: root.appendingPathComponent("src/app.js").path, contents: Data())
    return root
}

@Suite("WorkspaceFilePanelController", .serialized)
@MainActor
struct WorkspaceFilePanelTests {
    private func makePanel(
        root: URL, mode: WorkspaceFilePanelMode
    ) async -> WorkspaceFilePanelController {
        let panel = WorkspaceFilePanelController(
            lister: FileSystemLister(), root: root, mode: mode)
        await panel.sidebar.waitForPendingLoads()
        return panel
    }

    @discardableResult
    private func select(_ path: String, in panel: WorkspaceFilePanelController) -> Bool {
        let selected = panel.sidebar.selectItem(path: path)
        panel.selectionDidChange()
        return selected
    }

    // MARK: - openDirectory

    @Test func openDirectoryConfirmsRootWhenNothingSelected() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openDirectory)

        #expect(panel.selectedPath == root.path)
        #expect(panel.confirm() == root.path)
    }

    @Test func openDirectoryEnablesConfirmForDirectoryRow() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openDirectory)
        let src = root.appendingPathComponent("src").path

        #expect(select(src, in: panel))
        #expect(panel.selectedPath == src)
    }

    @Test func openDirectoryDisablesConfirmForFileRow() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openDirectory)
        let readme = root.appendingPathComponent("README.md").path

        #expect(select(readme, in: panel))
        #expect(panel.selectedPath == nil)
    }

    // MARK: - openFile

    @Test func openFileDisablesConfirmWhenNothingSelected() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openFile)

        #expect(panel.selectedPath == nil)
        #expect(panel.confirm() == nil)
    }

    @Test func openFileDisablesConfirmForDirectoryRow() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openFile)
        let src = root.appendingPathComponent("src").path

        #expect(select(src, in: panel))
        #expect(panel.selectedPath == nil)
    }

    @Test func openFileEnablesConfirmForFileRow() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openFile)
        let readme = root.appendingPathComponent("README.md").path

        #expect(select(readme, in: panel))
        #expect(panel.selectedPath == readme)
        #expect(panel.confirm() == readme)
    }

    // MARK: - saveFile

    @Test func saveFileComposesRootAndDefaultNameWhenNothingSelected() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .saveFile(defaultName: "untitled.txt"))

        #expect(panel.selectedPath == root.appendingPathComponent("untitled.txt").path)
    }

    @Test func saveFileComposesSelectedDirectoryAndName() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .saveFile(defaultName: "untitled.txt"))
        let src = root.appendingPathComponent("src").path

        #expect(select(src, in: panel))
        #expect(panel.selectedPath == root.appendingPathComponent("src/untitled.txt").path)
    }

    @Test func saveFilePrefillsNameFromSelectedFileAndTargetsItsParent() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .saveFile(defaultName: "untitled.txt"))
        let readme = root.appendingPathComponent("README.md").path

        #expect(select(readme, in: panel))
        #expect(panel.nameField?.stringValue == "README.md")
        #expect(panel.selectedPath == readme)
    }

    @Test func saveFileDisablesOnEmptyName() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .saveFile(defaultName: "untitled.txt"))
        panel.nameField?.stringValue = ""

        #expect(panel.selectedPath == nil)
        #expect(panel.confirm() == nil)
    }

    @Test func saveFileDisablesOnSlashInName() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .saveFile(defaultName: "untitled.txt"))
        panel.nameField?.stringValue = "nested/name.txt"

        #expect(panel.selectedPath == nil)
    }

    // MARK: - Cancel / completion

    @Test func cancelYieldsNil() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openDirectory)
        var received: [String?] = []
        panel.completion = { received.append($0) }

        panel.cancel()
        #expect(received.count == 1)
        #expect(received.first! == nil)
    }

    @Test func completionFiresExactlyOnceOnConfirm() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openDirectory)
        var received: [String?] = []
        panel.completion = { received.append($0) }

        #expect(panel.confirm() == root.path)
        // A second confirm (or a stray cancel) after finishing must not
        // deliver a second completion.
        _ = panel.confirm()
        panel.cancel()
        #expect(received == [root.path])
    }

    @Test func completionFiresExactlyOnceOnCancel() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let panel = await makePanel(root: root, mode: .openFile)
        var callCount = 0
        panel.completion = { _ in callCount += 1 }

        panel.cancel()
        panel.cancel()
        _ = panel.confirm()
        #expect(callCount == 1)
    }
}
