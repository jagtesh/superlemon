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
}
