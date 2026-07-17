import AppKit
import Foundation
import Testing

@testable import ShellKit

// MARK: - Fixtures

private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShellKitTransfer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every byte value, repeated: catches encoding/truncation bugs.
private func binaryFixtureData() -> Data {
    var data = Data()
    for _ in 0..<32 {
        data.append(contentsOf: (0...255).map { UInt8($0) })
    }
    return data
}

// MARK: - Local transport

@Suite("LocalWorkspaceFileTransport")
struct LocalWorkspaceFileTransportTests {

    @Test func roundTripsBytesWithMonotonicProgress() async throws {
        let root = try makeTempDir("local")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = binaryFixtureData()
        let source = root.appendingPathComponent("source.bin")
        try payload.write(to: source)

        let transport = LocalWorkspaceFileTransport()
        let destination = root.appendingPathComponent("copied.bin").path
        let lock = NSLock()
        nonisolated(unsafe) var ticks: [Int64] = []
        try await transport.writeFile(from: source, to: destination) { transferred, total in
            lock.withLock { ticks.append(transferred) }
            #expect(total == Int64(payload.count))
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == payload)
        let observed = lock.withLock { ticks }
        #expect(observed == observed.sorted())
        #expect(observed.last == Int64(payload.count))

        let stat = try await transport.stat(destination)
        #expect(stat?.isDirectory == false)
        #expect(stat?.size == Int64(payload.count))
        #expect(try await transport.stat(root.appendingPathComponent("nope").path) == nil)
    }

    @Test func replacesExistingFilesAtomicallyAndLeavesNoPartials() async throws {
        let root = try makeTempDir("replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("new.txt")
        try Data("new contents".utf8).write(to: source)
        let destination = root.appendingPathComponent("target.txt")
        try Data("old".utf8).write(to: destination)

        let transport = LocalWorkspaceFileTransport()
        try await transport.writeFile(from: source, to: destination.path) { _, _ in }

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new contents")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("superlemon-partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func moveNeverReplacesAnExistingDestination() async throws {
        let root = try makeTempDir("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalWorkspaceFileTransport()
        let a = root.appendingPathComponent("a.txt").path
        let b = root.appendingPathComponent("b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: a))
        try Data("b".utf8).write(to: URL(fileURLWithPath: b))

        await #expect(throws: (any Error).self) {
            try await transport.move(a, to: b)
        }
        #expect(try String(contentsOf: URL(fileURLWithPath: b), encoding: .utf8) == "b")
    }
}

// MARK: - Scripted transport (in-memory workspace)

/// In-memory workspace filesystem for coordinator tests.
private final class ScriptedTransport: WorkspaceFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String>
    private(set) var moves: [(from: String, to: String)] = []

    init(root: String) {
        directories = [root]
    }

    func contents(_ path: String) -> Data? { lock.withLock { files[path] } }
    func hasDirectory(_ path: String) -> Bool { lock.withLock { directories.contains(path) } }
    func recordedMoves() -> [(from: String, to: String)] { lock.withLock { moves } }
    func seed(file path: String, data: Data) { lock.withLock { files[path] = data } }
    func seed(directory path: String) { _ = lock.withLock { directories.insert(path) } }
    func allFiles() -> [String: Data] { lock.withLock { files } }

    func stat(_ path: String) async throws -> WorkspaceTransferStat? {
        lock.withLock {
            if directories.contains(path) {
                return WorkspaceTransferStat(isDirectory: true, size: 0)
            }
            if let data = files[path] {
                return WorkspaceTransferStat(isDirectory: false, size: Int64(data.count))
            }
            return nil
        }
    }

    func createDirectory(_ path: String) async throws {
        _ = lock.withLock { directories.insert(path) }
    }

    func move(_ source: String, to destination: String) async throws {
        try lock.withLock {
            guard files[destination] == nil, !directories.contains(destination) else {
                throw CocoaError(.fileWriteFileExists)
            }
            if let data = files.removeValue(forKey: source) {
                files[destination] = data
            } else if directories.remove(source) != nil {
                directories.insert(destination)
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
            moves.append((source, destination))
        }
    }

    func writeFile(
        from local: URL, to path: String,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        let data = try Data(contentsOf: local)
        lock.withLock { files[path] = data }
        progress(Int64(data.count), Int64(data.count))
    }

    func readFile(
        _ path: String, to local: URL,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        guard let data = lock.withLock({ files[path] }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try data.write(to: local)
        progress(Int64(data.count), Int64(data.count))
    }
}

/// Lister over the scripted transport, for export-tree walks.
private struct ScriptedLister: DirectoryLister {
    let entriesByPath: [String: [DirectoryEntry]]

    func list(_ url: URL) async throws -> [DirectoryEntry] {
        entriesByPath[url.path] ?? []
    }
}

// MARK: - Coordinator

@Suite("WorkspaceFileTransferCoordinator", .serialized)
@MainActor
struct WorkspaceFileTransferCoordinatorTests {

    private func makeCoordinator(
        transport: ScriptedTransport,
        lister: DirectoryLister = ScriptedLister(entriesByPath: [:])
    ) -> WorkspaceFileTransferCoordinator {
        WorkspaceFileTransferCoordinator(transport: transport, lister: lister)
    }

    @Test func importsDirectoryTreesRecursively() async throws {
        let local = try makeTempDir("import")
        defer { try? FileManager.default.removeItem(at: local) }
        try FileManager.default.createDirectory(
            at: local.appendingPathComponent("pkg/nested"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: local.appendingPathComponent("top.txt"))
        try Data("leaf".utf8).write(to: local.appendingPathComponent("pkg/nested/leaf.txt"))

        let transport = ScriptedTransport(root: "/ws")
        let coordinator = makeCoordinator(transport: transport)
        var changed: Set<String> = []
        var progressSnapshots: [WorkspaceTransferProgress?] = []
        coordinator.onWorkspaceChanged = { changed = $0 }
        coordinator.onProgress = { progressSnapshots.append($0) }

        coordinator.importItems(
            [local.appendingPathComponent("top.txt"), local.appendingPathComponent("pkg")],
            into: "/ws")
        await coordinator.waitForIdle()

        #expect(transport.contents("/ws/top.txt") == Data("top".utf8))
        #expect(transport.hasDirectory("/ws/pkg"))
        #expect(transport.hasDirectory("/ws/pkg/nested"))
        #expect(transport.contents("/ws/pkg/nested/leaf.txt") == Data("leaf".utf8))
        #expect(changed.contains("/ws"))
        #expect(progressSnapshots.contains { $0?.incoming == true })
        #expect((progressSnapshots.last ?? nil) == nil, "idle publishes nil progress")
    }

    @Test func conflictsResolveAsKeepBothReplaceOrCancel() async throws {
        let local = try makeTempDir("conflict")
        defer { try? FileManager.default.removeItem(at: local) }
        let dropped = local.appendingPathComponent("notes.txt")
        try Data("dropped".utf8).write(to: dropped)

        for resolution in [
            WorkspaceFileTransferCoordinator.ConflictResolution.keepBoth, .replace, .cancel,
        ] {
            let transport = ScriptedTransport(root: "/ws")
            transport.seed(file: "/ws/notes.txt", data: Data("existing".utf8))
            let coordinator = makeCoordinator(transport: transport)
            var asked: [String] = []
            coordinator.resolveConflicts = { names in
                asked = names
                return resolution
            }
            coordinator.importItems([dropped], into: "/ws")
            await coordinator.waitForIdle()
            #expect(asked == ["notes.txt"])

            switch resolution {
            case .keepBoth:
                #expect(transport.contents("/ws/notes.txt") == Data("existing".utf8))
                #expect(transport.contents("/ws/notes 2.txt") == Data("dropped".utf8))
            case .replace:
                #expect(transport.contents("/ws/notes.txt") == Data("dropped".utf8))
                #expect(transport.contents("/ws/notes 2.txt") == nil)
            case .cancel:
                #expect(transport.contents("/ws/notes.txt") == Data("existing".utf8))
                #expect(transport.allFiles().count == 1)
            }
        }
    }

    @Test func movesSkipSameParentAndRefuseOwnSubtree() async throws {
        let transport = ScriptedTransport(root: "/ws")
        transport.seed(directory: "/ws/dir")
        transport.seed(directory: "/ws/other")
        transport.seed(file: "/ws/dir/file.txt", data: Data("f".utf8))
        let coordinator = makeCoordinator(transport: transport)
        var errors: [String] = []
        coordinator.onError = { errors.append($0) }

        // Same parent: nothing to do, no error.
        coordinator.moveItems(["/ws/dir/file.txt"], into: "/ws/dir")
        await coordinator.waitForIdle()
        #expect(transport.recordedMoves().isEmpty)
        #expect(errors.isEmpty)

        // Into its own subtree: refused with an error.
        coordinator.moveItems(["/ws/dir"], into: "/ws/dir")
        await coordinator.waitForIdle()
        #expect(transport.recordedMoves().isEmpty)
        #expect(errors.count == 1)

        // A real move.
        coordinator.moveItems(["/ws/dir/file.txt"], into: "/ws/other")
        await coordinator.waitForIdle()
        #expect(transport.contents("/ws/other/file.txt") == Data("f".utf8))
        #expect(transport.contents("/ws/dir/file.txt") == nil)
    }

    @Test func exportsDirectoryTreesThroughTheLister() async throws {
        let destination = try makeTempDir("export")
        defer { try? FileManager.default.removeItem(at: destination) }

        let transport = ScriptedTransport(root: "/ws")
        transport.seed(directory: "/ws/pkg")
        transport.seed(directory: "/ws/pkg/nested")
        transport.seed(file: "/ws/pkg/a.txt", data: Data("a".utf8))
        transport.seed(file: "/ws/pkg/nested/b.txt", data: Data("b".utf8))
        let lister = ScriptedLister(entriesByPath: [
            "/ws/pkg": [
                DirectoryEntry(name: "a.txt", isDirectory: false),
                DirectoryEntry(name: "nested", isDirectory: true),
                DirectoryEntry(name: ".git", isDirectory: true),
            ],
            "/ws/pkg/nested": [DirectoryEntry(name: "b.txt", isDirectory: false)],
        ])
        let coordinator = makeCoordinator(transport: transport, lister: lister)

        let target = destination.appendingPathComponent("pkg")
        try await coordinator.exportItem(at: "/ws/pkg", isDirectory: true, to: target)

        #expect(
            try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8) == "a")
        #expect(
            try String(
                contentsOf: target.appendingPathComponent("nested/b.txt"), encoding: .utf8) == "b")
        #expect(
            !FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path),
            ".git never exports")
    }

    @Test func secondBatchWhileActiveIsRefusedNotInterleaved() async throws {
        let local = try makeTempDir("busy")
        defer { try? FileManager.default.removeItem(at: local) }
        let file = local.appendingPathComponent("f.txt")
        try Data("f".utf8).write(to: file)

        let transport = ScriptedTransport(root: "/ws")
        let coordinator = makeCoordinator(transport: transport)
        var errors: [String] = []
        coordinator.onError = { errors.append($0) }

        coordinator.importItems([file], into: "/ws")
        coordinator.importItems([file], into: "/ws")  // refused: busy
        await coordinator.waitForIdle()

        #expect(errors.count == 1)
        #expect(transport.contents("/ws/f.txt") == Data("f".utf8))
    }
}

// MARK: - Sidebar drop plumbing

@Suite("FileTreeSidebarView drag & drop", .serialized)
@MainActor
struct FileTreeSidebarDragDropTests {

    private func makeLoadedSidebar() async throws -> (FileTreeSidebarView, URL) {
        let root = try makeTempDir("sidebar")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("m".utf8).write(to: root.appendingPathComponent("main.swift"))
        let sidebar = FileTreeSidebarView(frame: NSRect(x: 0, y: 0, width: 370, height: 400))
        sidebar.setRoot(root)
        await sidebar.waitForPendingLoads()
        return (sidebar, root)
    }

    @Test func anyRowResolvesToADirectoryTarget() async throws {
        let (sidebar, root) = try await makeLoadedSidebar()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootNode = try #require(sidebar.rootNode)
        let src = try #require(rootNode.findLoadedNode(path: root.appendingPathComponent("src").path))
        let file = try #require(
            rootNode.findLoadedNode(path: root.appendingPathComponent("main.swift").path))

        #expect(sidebar.dropTargetDirectory(for: nil) === rootNode, "empty area → root")
        #expect(sidebar.dropTargetDirectory(for: src) === src, "directory row → itself")
        #expect(sidebar.dropTargetDirectory(for: file) === rootNode, "file row → its parent")
    }

    @Test func internalMovesExcludeSameParentAndOwnSubtree() async throws {
        let (sidebar, root) = try await makeLoadedSidebar()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcPath = root.appendingPathComponent("src").standardizedFileURL.path
        let filePath = root.appendingPathComponent("main.swift").standardizedFileURL.path

        sidebar.draggedNodePaths = [filePath]
        #expect(sidebar.movablePaths(into: srcPath) == [filePath])
        #expect(
            sidebar.movablePaths(into: (filePath as NSString).deletingLastPathComponent).isEmpty,
            "same parent is a no-op")

        sidebar.draggedNodePaths = [srcPath]
        #expect(sidebar.movablePaths(into: srcPath).isEmpty, "into itself")
        #expect(sidebar.movablePaths(into: srcPath + "/deeper").isEmpty, "into its own subtree")
    }

    @Test func transferBandAppearsWithProgressAndCollapsesWhenIdle() async throws {
        let (sidebar, root) = try await makeLoadedSidebar()
        defer { try? FileManager.default.removeItem(at: root) }

        func bandHeight() -> CGFloat {
            sidebar.layoutSubtreeIfNeeded()
            return sidebar.subviews
                .compactMap { $0 as? FileTransferProgressView }
                .first?.frame.height ?? -1
        }

        #expect(bandHeight() == 0)
        sidebar.renderTransferProgress(WorkspaceTransferProgress(
            itemName: "big.bin", completedItems: 1, totalItems: 3,
            currentFraction: 0.5, incoming: true))
        #expect(bandHeight() == FileTransferProgressView.bandHeight)

        sidebar.renderTransferProgress(nil)
        #expect(bandHeight() == 0)
    }
}
