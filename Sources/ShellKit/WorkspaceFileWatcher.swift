import CoreServices
import Darwin
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
    /// The root as the caller named it (may be a symlink) and its
    /// symlink-resolved form actually passed to FSEvents. FSEvents always
    /// reports canonical (resolved) paths, so a symlinked workspace root
    /// (e.g. `~/code` → `/Volumes/Data/code`) would otherwise never match
    /// the caller-facing root the sidebar's `isPath(inside:)` checks expect.
    /// Delivered paths are mapped back from `resolvedRootPath` to
    /// `callerRootPath` in `remapToCallerRoot`.
    private var callerRootPath = ""
    private var resolvedRootPath = ""

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
        // FSEvents reports canonical, symlink-resolved paths regardless of
        // what path was handed to FSEventStreamCreate — and it reports the
        // TRUE canonical form including "/private", which URL's own
        // resolvingSymlinksInPath()/standardizedFileURL deliberately hide
        // for compatibility (e.g. /var/folders/... instead of /private/var/
        // folders/...). Use realpath(3) instead so the resolved form here
        // matches what the callback actually receives, byte for byte.
        // Remember both forms so delivered paths can be translated back to
        // the caller's root (Bug C: a symlinked workspace root).
        let resolved = Self.canonicalPath(of: root) ?? root
        callerRootPath = root.path
        resolvedRootPath = resolved.path
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
            [resolved.path] as CFArray,
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
        callerRootPath = ""
        resolvedRootPath = ""
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// realpath(3)-based canonicalization: the true resolved path FSEvents
    /// uses internally, including "/private" — unlike
    /// `URL.resolvingSymlinksInPath()`, which strips it for
    /// compatibility with `/tmp`, `/var`, `/etc` and would otherwise never
    /// match what the FSEvents callback delivers for a symlinked root.
    private static func canonicalPath(of url: URL) -> URL? {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Maps a path FSEvents delivered (in resolved/canonical form) back to
    /// the form the caller's root was given in, so the sidebar's
    /// `isPath(_:inside:)` prefix check — which compares against the
    /// caller-facing root path — keeps working unchanged. A no-op when the
    /// root wasn't a symlink (the two paths are identical) or when the
    /// incoming path isn't under the resolved root at all.
    private func remapToCallerRoot(_ path: String) -> String {
        guard !resolvedRootPath.isEmpty, resolvedRootPath != callerRootPath else { return path }
        if path == resolvedRootPath { return callerRootPath }
        let resolvedPrefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath : resolvedRootPath + "/"
        guard path.hasPrefix(resolvedPrefix) else { return path }
        let suffix = path.dropFirst(resolvedPrefix.count)
        let callerPrefix = callerRootPath.hasSuffix("/") ? callerRootPath : callerRootPath + "/"
        return callerPrefix + suffix
    }

    /// Internal seam for deterministic debounce tests; production changes
    /// enter through the FSEvents callback below.
    func recordChanges(
        _ paths: [String],
        flags: [FSEventStreamEventFlags] = []
    ) {
        pendingPaths.formUnion(paths.map(remapToCallerRoot))
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
