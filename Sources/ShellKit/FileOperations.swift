// FileOperations — the actual FileManager mutations behind the sidebar's
// context menu. The sidebar itself only *emits* `FileOperation` values via
// its `onFileOperation` callback; the embedder (app layer) decides when to
// call these and then reloads the affected subtree. The current app does not
// yet reconcile renamed or deleted paths with open nvim buffers (DESIGN §14.1).

import Foundation

/// A file mutation (or navigation) requested from the sidebar UI.
/// Carries absolute paths.
public enum FileOperation: Equatable, Sendable {
    case newFile(directory: String, name: String)
    case newFolder(directory: String, name: String)
    case rename(path: String, newName: String)
    case trash(path: String)
    case revealInFinder(path: String)
}

public enum FileOperationError: Error, Equatable {
    case alreadyExists(String)
    case notFound(String)
    case invalidName(String)
}

public enum FileOperations {

    /// Creates an empty file `name` inside `directory`. Fails if it exists.
    @discardableResult
    public static func createFile(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(try validated(name))
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw FileOperationError.alreadyExists(url.path)
        }
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw FileOperationError.notFound(directory.path)
        }
        return url
    }

    /// Creates a folder `name` inside `directory`. Fails if it exists.
    @discardableResult
    public static func createFolder(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(try validated(name))
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw FileOperationError.alreadyExists(url.path)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames the item at `url` to `newName` within the same directory.
    @discardableResult
    public static func rename(at url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(try validated(newName))
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw FileOperationError.notFound(url.path)
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw FileOperationError.alreadyExists(destination.path)
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves the item to the Trash. Falls back to permanent removal when
    /// the Trash is unavailable (e.g. sandboxed test runners, volumes
    /// without a .Trashes folder) so "Delete" always deletes.
    public static func trash(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw FileOperationError.notFound(url.path)
        }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try fm.removeItem(at: url)
        }
    }

    /// Applies a mutating operation. `.revealInFinder` is a no-op here
    /// (pure UI concern — the embedder calls NSWorkspace).
    public static func perform(_ operation: FileOperation) throws {
        switch operation {
        case let .newFile(directory, name):
            try createFile(in: URL(fileURLWithPath: directory), name: name)
        case let .newFolder(directory, name):
            try createFolder(in: URL(fileURLWithPath: directory), name: name)
        case let .rename(path, newName):
            try rename(at: URL(fileURLWithPath: path), to: newName)
        case let .trash(path):
            try trash(URL(fileURLWithPath: path))
        case .revealInFinder:
            break
        }
    }

    private static func validated(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileOperationError.invalidName(name)
        }
        return name
    }
}
