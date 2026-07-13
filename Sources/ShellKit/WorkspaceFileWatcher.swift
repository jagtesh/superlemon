import CoreServices
import Foundation

public enum WorkspaceFileWatcherError: Error, LocalizedError {
    case couldNotCreateStream(String)
    case couldNotStartStream(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateStream(let path):
            return "Could not watch \(path) for filesystem changes."
        case .couldNotStartStream(let path):
            return "Could not start filesystem monitoring for \(path)."
        }
    }
}

public struct WorkspaceFileChangeBatch: Sendable, Equatable {
    public let paths: Set<String>
    public let requiresFullRescan: Bool

    public init(paths: Set<String>, requiresFullRescan: Bool = false) {
        self.paths = paths
        self.requiresFullRescan = requiresFullRescan
    }
}

/// Recursive macOS FSEvents watcher with a trailing-edge debounce. FSEvents
/// can deliver a burst for one save (temporary file, rename, metadata), so
/// consumers receive one coalesced path set rather than refreshing per event.
@MainActor
public final class WorkspaceFileWatcher {
    public var onChange: ((WorkspaceFileChangeBatch) -> Void)?

    private let debounce: Duration
    private let eventLatency: CFTimeInterval
    // `deinit` is nonisolated in Swift 6; unsafe is narrowly scoped to this
    // opaque C handle so it can still be invalidated during teardown.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var pendingPaths: Set<String> = []
    private var pendingFullRescan = false

    public init(
        debounce: Duration = .milliseconds(250),
        eventLatency: CFTimeInterval = 0.05
    ) {
        self.debounce = debounce
        self.eventLatency = eventLatency
    }

    public func start(watching root: URL) throws {
        stop()
        let root = root.standardizedFileURL
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            workspaceFileWatcherCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            eventLatency,
            flags)
        else {
            throw WorkspaceFileWatcherError.couldNotCreateStream(root.path)
        }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WorkspaceFileWatcherError.couldNotStartStream(root.path)
        }
        stream = created
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths.removeAll()
        pendingFullRescan = false
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Internal seam for deterministic debounce tests; production changes
    /// enter through the FSEvents callback below.
    func recordChanges(
        _ paths: [String],
        flags: [FSEventStreamEventFlags] = []
    ) {
        pendingPaths.formUnion(paths)
        let rescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped)
        pendingFullRescan = pendingFullRescan
            || flags.contains(where: { $0 & rescanMask != 0 })
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let batch = pendingPaths
            let requiresFullRescan = pendingFullRescan
            pendingPaths.removeAll()
            pendingFullRescan = false
            debounceTask = nil
            guard !batch.isEmpty || requiresFullRescan else { return }
            onChange?(WorkspaceFileChangeBatch(
                paths: batch, requiresFullRescan: requiresFullRescan))
        }
    }

    /// Test/diagnostic hook that observes the real debounce task without a
    /// second wall-clock guess in callers.
    func waitForPendingDelivery() async {
        await debounceTask?.value
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private func workspaceFileWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let watcher = Unmanaged<WorkspaceFileWatcher>
        .fromOpaque(clientInfo).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes: eventPaths is a CFArray of
    // CFString; bridge it rather than reinterpreting the raw pointer.
    let paths =
        Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        as? [String] ?? []
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
    Task { @MainActor in watcher.recordChanges(paths, flags: flags) }
}
