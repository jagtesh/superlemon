// WorkspaceFileTransfer — drag-and-drop file movement between the local
// machine and the workspace filesystem, wherever that filesystem lives.
//
// `WorkspaceFileTransport` is the per-file primitive seam (the third
// sibling of DirectoryLister and WorkspaceIndexSource): the local
// implementation streams through FileManager/FileHandle, and a
// session-backed implementation streams chunks over the editor's RPC
// channel. `WorkspaceFileTransferCoordinator` owns everything above the
// primitives: recursive plans, conflict resolution, sequential execution,
// aggregate progress, and cancellation.

import Foundation

public struct WorkspaceTransferStat: Sendable {
    public let isDirectory: Bool
    public let size: Int64

    public init(isDirectory: Bool, size: Int64) {
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// Byte-level progress: (bytes transferred so far, total bytes).
public typealias WorkspaceTransferProgressHandler = @Sendable (Int64, Int64) -> Void

/// Moves file bytes between the LOCAL machine and the workspace filesystem.
/// `path` arguments are workspace-absolute; `local` URLs are always on this
/// machine. Writes must be atomic: a failed or cancelled `writeFile` leaves
/// neither a torn target nor debris.
public protocol WorkspaceFileTransport: Sendable {
    /// nil when nothing exists at `path`.
    func stat(_ path: String) async throws -> WorkspaceTransferStat?
    /// mkdir -p; succeeds when the directory already exists.
    func createDirectory(_ path: String) async throws
    /// Rename within the workspace. Never replaces an existing destination.
    func move(_ source: String, to destination: String) async throws
    /// Streams the local file to `path`, replacing any existing file.
    func writeFile(
        from local: URL, to path: String,
        progress: @escaping WorkspaceTransferProgressHandler) async throws
    /// Streams the workspace file at `path` to the local URL.
    func readFile(
        _ path: String, to local: URL,
        progress: @escaping WorkspaceTransferProgressHandler) async throws
}

public enum WorkspaceTransferError: LocalizedError {
    case busy
    case unreadableSource(String)
    case destinationInsideSource(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            "A file transfer is already in progress. Wait for it to finish (or cancel it) first."
        case .unreadableSource(let path):
            "Couldn’t read \(path)."
        case .destinationInsideSource(let path):
            "Can’t move “\((path as NSString).lastPathComponent)” into itself."
        }
    }
}

// MARK: - Local transport (the fast path)

public struct LocalWorkspaceFileTransport: WorkspaceFileTransport {
    /// 1 MiB: large enough to saturate local disks, small enough for
    /// per-chunk progress and prompt cancellation.
    static let chunkSize = 1 << 20

    public init() {}

    public func stat(_ path: String) async throws -> WorkspaceTransferStat? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return WorkspaceTransferStat(isDirectory: isDirectory.boolValue, size: size)
    }

    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    public func move(_ source: String, to destination: String) async throws {
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    public func writeFile(
        from local: URL, to path: String,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        try Self.streamCopy(from: local.path, to: path, progress: progress)
    }

    public func readFile(
        _ path: String, to local: URL,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        try Self.streamCopy(from: path, to: local.path, progress: progress)
    }

    /// Chunked copy through a partial sibling, renamed over the target on
    /// success — the same no-torn-files guarantee the RPC transport gives.
    static func streamCopy(
        from sourcePath: String, to destinationPath: String,
        progress: WorkspaceTransferProgressHandler
    ) throws {
        guard sourcePath != destinationPath else { return }
        guard let input = FileHandle(forReadingAtPath: sourcePath) else {
            throw WorkspaceTransferError.unreadableSource(sourcePath)
        }
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        let total = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let partialPath = destinationPath + ".superlemon-partial-\(UUID().uuidString.prefix(8))"
        FileManager.default.createFile(atPath: partialPath, contents: nil)
        guard let output = FileHandle(forWritingAtPath: partialPath) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var committed = false
        defer {
            try? output.close()
            if !committed { try? FileManager.default.removeItem(atPath: partialPath) }
        }

        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            written += Int64(data.count)
            progress(written, total)
        }
        try output.close()
        // rename(2) atomically replaces an existing destination file.
        guard rename(partialPath, destinationPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true
        progress(max(written, total), total)
    }
}

// MARK: - Progress model

public struct WorkspaceTransferProgress: Equatable, Sendable {
    /// Basename of the file currently moving.
    public let itemName: String
    public let completedItems: Int
    public let totalItems: Int
    /// 0…1 through the current file.
    public let currentFraction: Double
    /// True when bytes flow INTO the workspace (drop/import), false when
    /// they flow out to the local machine (drag-out/download).
    public let incoming: Bool

    public init(
        itemName: String, completedItems: Int, totalItems: Int,
        currentFraction: Double, incoming: Bool
    ) {
        self.itemName = itemName
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentFraction = min(1, max(0, currentFraction))
        self.incoming = incoming
    }

    public var overallFraction: Double {
        (Double(completedItems) + currentFraction) / Double(max(1, totalItems))
    }
}

// MARK: - Coordinator

/// Orchestrates drag-and-drop batches over one transport. Single batch at a
/// time: drops during an active transfer are refused through `onError`
/// rather than interleaved. All callbacks fire on the main actor.
@MainActor
public final class WorkspaceFileTransferCoordinator {
    public enum ConflictResolution: Sendable {
        case replace
        case keepBoth
        case cancel
    }

    private let transport: any WorkspaceFileTransport
    private let lister: any DirectoryLister

    /// Live progress; nil when the coordinator returns to idle.
    public var onProgress: ((WorkspaceTransferProgress?) -> Void)?
    public var onError: ((String) -> Void)?
    /// Asked once per batch with the destination names that already exist.
    /// Unset resolves as `.keepBoth` (never destroys data silently).
    public var resolveConflicts: (@MainActor ([String]) async -> ConflictResolution)?
    /// Workspace-absolute directories whose contents changed.
    public var onWorkspaceChanged: ((Set<String>) -> Void)?

    public private(set) var isActive = false
    /// Cancels the running batch/export task (type-erased: batches never
    /// throw out of their Task, exports do).
    private var cancelActiveTask: (() -> Void)?
    private var activeBatchTask: Task<Void, Never>?

    public init(transport: any WorkspaceFileTransport, lister: any DirectoryLister) {
        self.transport = transport
        self.lister = lister
    }

    public func cancelActiveTransfers() {
        cancelActiveTask?()
    }

    /// Test/diagnostic hook: resolves when the running batch (if any) ends.
    public func waitForIdle() async {
        await activeBatchTask?.value
    }

    // MARK: Import (local machine → workspace)

    private struct PlanEntry: Sendable {
        let localURL: URL
        let workspacePath: String
        let isDirectory: Bool
    }

    /// Copies dropped local items (files or directory trees) into the
    /// workspace directory.
    public func importItems(_ urls: [URL], into directory: String) {
        runBatch { coordinator in
            var changed: Set<String> = [directory]
            var plan: [PlanEntry] = []
            var conflicted: [String] = []
            var topLevel: [(url: URL, name: String, exists: Bool)] = []
            for url in urls {
                let name = url.lastPathComponent
                let exists = try await coordinator.transport.stat(
                    Self.join(directory, name)) != nil
                // Only names that collide with something already on disk go
                // to the conflict prompt; two dropped items sharing a
                // basename (no pre-existing file) are uniqued silently below.
                if exists, !conflicted.contains(name) { conflicted.append(name) }
                topLevel.append((url, name, exists))
            }

            var resolution = ConflictResolution.keepBoth
            if !conflicted.isEmpty {
                resolution = await coordinator.resolveConflicts?(conflicted) ?? .keepBoth
                if case .cancel = resolution { return }
            }

            // Names claimed so far in this batch — guards against two
            // dropped items resolving to the same destination and one
            // silently clobbering the other, regardless of the chosen
            // conflict resolution for pre-existing files.
            var claimedNames: Set<String> = []
            for item in topLevel {
                var name = item.name
                let mustUnique: Bool
                if case .keepBoth = resolution {
                    mustUnique = item.exists
                } else {
                    mustUnique = false
                }
                if mustUnique || claimedNames.contains(name) {
                    name = try await coordinator.availableName(
                        for: name, in: directory, reserved: claimedNames)
                }
                claimedNames.insert(name)
                try Self.appendImportPlan(
                    for: item.url,
                    workspacePath: Self.join(directory, name),
                    into: &plan)
            }

            let files = plan.filter { !$0.isDirectory }
            var completed = 0
            for entry in plan {
                try Task.checkCancellation()
                if entry.isDirectory {
                    try await coordinator.transport.createDirectory(entry.workspacePath)
                    changed.insert(entry.workspacePath)
                    continue
                }
                coordinator.publishProgress(
                    name: entry.localURL.lastPathComponent,
                    completed: completed, total: files.count,
                    fraction: 0, incoming: true)
                try await coordinator.transport.writeFile(
                    from: entry.localURL, to: entry.workspacePath,
                    progress: coordinator.fileProgressHandler(
                        name: entry.localURL.lastPathComponent,
                        completed: completed, total: files.count, incoming: true))
                completed += 1
                changed.insert((entry.workspacePath as NSString).deletingLastPathComponent)
            }
            coordinator.onWorkspaceChanged?(changed)
        }
    }

    /// Recursive local walk, parents before children so remote mkdir can
    /// run in plan order. Only regular files and directories transfer,
    /// matching the sidebar/index view of the world.
    private static func appendImportPlan(
        for url: URL, workspacePath: String, into plan: inout [PlanEntry]
    ) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceTransferError.unreadableSource(url.path)
        }
        guard url.path != workspacePath else { return }  // dropped onto itself
        if !isDirectory.boolValue {
            plan.append(PlanEntry(localURL: url, workspacePath: workspacePath, isDirectory: false))
            return
        }
        plan.append(PlanEntry(localURL: url, workspacePath: workspacePath, isDirectory: true))
        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard values?.isDirectory == true || values?.isRegularFile == true else { continue }
            try appendImportPlan(
                for: child,
                workspacePath: join(workspacePath, child.lastPathComponent),
                into: &plan)
        }
    }

    /// Finder-style "name 2.ext", "name 3.ext", … first name that is free
    /// both on disk and among `reserved` names already claimed earlier in
    /// this batch (so two dropped items sharing a basename never collide).
    private func availableName(
        for name: String, in directory: String, reserved: Set<String> = []
    ) async throws -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for counter in 2...9999 {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if reserved.contains(candidate) { continue }
            if try await transport.stat(Self.join(directory, candidate)) == nil {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    // MARK: Move (within the workspace)

    public func moveItems(_ paths: [String], into directory: String) {
        runBatch { coordinator in
            var changed: Set<String> = []
            for path in paths {
                let destination = Self.join(directory, (path as NSString).lastPathComponent)
                guard destination != path else { continue }
                if directory == path || directory.hasPrefix(path + "/") {
                    throw WorkspaceTransferError.destinationInsideSource(path)
                }
                try await coordinator.transport.move(path, to: destination)
                changed.insert((path as NSString).deletingLastPathComponent)
                changed.insert(directory)
            }
            if !changed.isEmpty { coordinator.onWorkspaceChanged?(changed) }
        }
    }

    // MARK: Export (workspace → local machine, drag-out fulfillment)

    /// Streams a workspace file or directory tree to `destination` on this
    /// machine (an NSFilePromiseProvider fulfillment URL). Throws to let the
    /// promise report failure; progress still flows through `onProgress`.
    public func exportItem(
        at path: String, isDirectory: Bool, to destination: URL
    ) async throws {
        guard !isActive else { throw WorkspaceTransferError.busy }
        isActive = true
        defer {
            isActive = false
            onProgress?(nil)
        }
        let task = Task { [self] in
            var files: [(workspace: String, local: URL)] = []
            try await appendExportPlan(
                path: path, isDirectory: isDirectory,
                destination: destination, files: &files)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let name = (file.workspace as NSString).lastPathComponent
                publishProgress(
                    name: name, completed: index, total: files.count,
                    fraction: 0, incoming: false)
                try await transport.readFile(
                    file.workspace, to: file.local,
                    progress: fileProgressHandler(
                        name: name, completed: index, total: files.count,
                        incoming: false))
            }
        }
        cancelActiveTask = { task.cancel() }
        defer { cancelActiveTask = nil }
        try await task.value
    }

    /// Directories materialize locally as they are discovered; files queue
    /// for the streaming pass. Remote listings come through the same lister
    /// the sidebar renders from.
    private func appendExportPlan(
        path: String, isDirectory: Bool, destination: URL,
        files: inout [(workspace: String, local: URL)]
    ) async throws {
        guard isDirectory else {
            files.append((path, destination))
            return
        }
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        for entry in try await lister.list(URL(fileURLWithPath: path, isDirectory: true))
        where entry.name != ".git" {
            try await appendExportPlan(
                path: Self.join(path, entry.name),
                isDirectory: entry.isDirectory,
                destination: destination.appendingPathComponent(entry.name),
                files: &files)
        }
    }

    // MARK: Shared machinery

    private func runBatch(
        _ body: @escaping @MainActor (WorkspaceFileTransferCoordinator) async throws -> Void
    ) {
        guard !isActive else {
            onError?(WorkspaceTransferError.busy.localizedDescription)
            return
        }
        isActive = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
            } catch is CancellationError {
                // User-initiated: partials are already cleaned by transports.
            } catch {
                self.onError?(error.localizedDescription)
            }
            self.isActive = false
            self.cancelActiveTask = nil
            self.activeBatchTask = nil
            self.onProgress?(nil)
        }
        cancelActiveTask = { task.cancel() }
        activeBatchTask = task
    }

    private func publishProgress(
        name: String, completed: Int, total: Int, fraction: Double, incoming: Bool
    ) {
        onProgress?(WorkspaceTransferProgress(
            itemName: name, completedItems: completed, totalItems: total,
            currentFraction: fraction, incoming: incoming))
    }

    private func fileProgressHandler(
        name: String, completed: Int, total: Int, incoming: Bool
    ) -> WorkspaceTransferProgressHandler {
        { [weak self] transferred, size in
            let fraction = size > 0 ? Double(transferred) / Double(size) : 1
            Task { @MainActor [weak self] in
                self?.publishProgress(
                    name: name, completed: completed, total: total,
                    fraction: fraction, incoming: incoming)
            }
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
