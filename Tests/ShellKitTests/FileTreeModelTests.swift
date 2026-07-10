import Foundation
import Testing
@testable import ShellKit

/// Wraps a lister and counts list() calls per directory — the laziness probe.
final class CountingLister: DirectoryLister, @unchecked Sendable {
    private let wrapped: DirectoryLister
    private(set) var listedPaths: [String] = []
    var totalCalls: Int { listedPaths.count }

    init(wrapping wrapped: DirectoryLister = FileSystemLister()) {
        self.wrapped = wrapped
    }

    func list(_ url: URL) -> [DirectoryEntry] {
        listedPaths.append(url.path)
        return wrapped.list(url)
    }
}

@Suite("FileTreeNode model", .serialized)
@MainActor
struct FileTreeModelTests {

    private func makeFixtureTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ShellKitTree-\(UUID().uuidString)")
        for dir in ["", "src", "src/deep", "docs", ".git"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true
            )
        }
        for file in ["main.swift", ".hidden", "src/app.js", "src/deep/leaf.md",
                     "docs/readme.md", ".git/config"] {
            fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }
        return root
    }

    @Test func childrenAreNotReadUntilFirstAccess() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()

        let node = FileTreeNode(url: root, isDirectory: true)
        #expect(lister.totalCalls == 0)
        #expect(!node.childrenLoaded)

        let children = node.children(using: lister, showHidden: false)
        #expect(lister.totalCalls == 1)
        #expect(node.childrenLoaded)

        // Child directories exist as nodes but were NOT listed.
        let src = try #require(children.first { $0.name == "src" })
        #expect(!src.childrenLoaded)
        #expect(lister.totalCalls == 1)
        #expect(lister.listedPaths == [root.path])

        // Repeated access is cached — no extra I/O.
        _ = node.children(using: lister, showHidden: false)
        #expect(lister.totalCalls == 1)

        // Expanding src lists exactly src — not src/deep.
        let srcChildren = src.children(using: lister, showHidden: false)
        #expect(lister.totalCalls == 2)
        #expect(lister.listedPaths.last == root.appendingPathComponent("src").path)
        let deep = try #require(srcChildren.first { $0.name == "deep" })
        #expect(!deep.childrenLoaded)
    }

    @Test func directoriesSortFirstThenCaseInsensitiveNames() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let node = FileTreeNode(url: root, isDirectory: true)
        let names = node.children(using: FileSystemLister(), showHidden: false).map(\.name)
        #expect(names == ["docs", "src", "main.swift"])
    }

    @Test func hiddenFilesToggleAndGitAlwaysHidden() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let node = FileTreeNode(url: root, isDirectory: true)
        let lister = FileSystemLister()

        let visible = node.children(using: lister, showHidden: false).map(\.name)
        #expect(!visible.contains(".hidden"))
        #expect(!visible.contains(".git"))

        let withHidden = node.children(using: lister, showHidden: true).map(\.name)
        #expect(withHidden.contains(".hidden"))
        #expect(!withHidden.contains(".git"))  // .git never shows
    }

    @Test func invalidateChildrenReloadsFromDisk() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()

        let node = FileTreeNode(url: root, isDirectory: true)
        let before = node.children(using: lister, showHidden: false).map(\.name)
        #expect(!before.contains("added.txt"))

        FileManager.default.createFile(
            atPath: root.appendingPathComponent("added.txt").path, contents: Data()
        )
        // Cached until invalidated.
        #expect(!node.children(using: lister, showHidden: false).map(\.name).contains("added.txt"))
        node.invalidateChildren()
        #expect(node.children(using: lister, showHidden: false).map(\.name).contains("added.txt"))
        #expect(lister.totalCalls == 2)
    }

    @Test func findLoadedNodeNeverTriggersIO() throws {
        let root = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let lister = CountingLister()

        let node = FileTreeNode(url: root, isDirectory: true)
        _ = node.children(using: lister, showHidden: false)
        let callsAfterLoad = lister.totalCalls

        // Finds a loaded node...
        let src = node.findLoadedNode(path: root.appendingPathComponent("src").path)
        #expect(src != nil)
        // ...returns nil for unloaded depths instead of listing them...
        let leaf = node.findLoadedNode(
            path: root.appendingPathComponent("src/deep/leaf.md").path
        )
        #expect(leaf == nil)
        // ...and never touched the lister.
        #expect(lister.totalCalls == callsAfterLoad)
    }
}
