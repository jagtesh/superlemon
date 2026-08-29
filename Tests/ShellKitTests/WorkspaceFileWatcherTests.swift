import CoreServices
import Foundation
import Testing
@testable import ShellKit

@Suite("WorkspaceFileWatcher", .serialized)
@MainActor
struct WorkspaceFileWatcherTests {
    @Test func coalescesBurstIntoOneTrailingEdgeBatch() async throws {
        let watcher = WorkspaceFileWatcher(debounce: .milliseconds(10))
        var batches: [WorkspaceFileChangeBatch] = []
        watcher.onChange = { batches.append($0) }

        watcher.recordChanges(["/project/a", "/project/a"])
        watcher.recordChanges(["/project/b"])
        await watcher.waitForPendingDelivery()

        #expect(batches == [WorkspaceFileChangeBatch(
            paths: Set(["/project/a", "/project/b"]))])
    }

    @Test func droppedEventsRequestOneFullRescan() async {
        let watcher = WorkspaceFileWatcher(debounce: .milliseconds(1))
        var batches: [WorkspaceFileChangeBatch] = []
        watcher.onChange = { batches.append($0) }

        watcher.recordChanges(
            ["/project"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)])
        watcher.recordChanges(["/project/a"])
        await watcher.waitForPendingDelivery()

        #expect(batches == [WorkspaceFileChangeBatch(
            paths: Set(["/project", "/project/a"]),
            requiresFullRescan: true)])
    }

    @Test func stopCancelsPendingDeliveryAndCanStartARealStream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellKitWatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = WorkspaceFileWatcher(debounce: .milliseconds(10))
        var deliveries = 0
        watcher.onChange = { _ in deliveries += 1 }
        watcher.recordChanges([root.path])
        watcher.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(deliveries == 0)

        try watcher.start(watching: root)
        watcher.stop()
    }

    @Test func symlinkedRootDeliversPathsInCallerForm() async throws {
        // FSEvents reports canonical (symlink-resolved) paths. Watching a
        // symlinked workspace root (e.g. `~/code` → `/Volumes/Data/code`)
        // must still deliver paths the caller recognizes as "inside" the
        // root it asked to watch, not the resolved target.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellKitWatcherSymlink-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let watcher = WorkspaceFileWatcher(debounce: .milliseconds(50))
        var batches: [WorkspaceFileChangeBatch] = []
        watcher.onChange = { batches.append($0) }
        try watcher.start(watching: link)
        defer { watcher.stop() }

        let touched = real.appendingPathComponent("touched.txt")
        FileManager.default.createFile(atPath: touched.path, contents: Data())

        // Real FSEvents delivery is asynchronous and outside the debounce
        // task's own control; poll rather than guess a fixed sleep.
        for _ in 0..<100 where batches.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }

        let delivered = try #require(batches.first)
        let linkPath = link.standardizedFileURL.path
        #expect(delivered.paths.contains { $0.hasPrefix(linkPath) })
        #expect(!delivered.paths.contains { $0.hasPrefix(real.standardizedFileURL.path) })
    }
}
