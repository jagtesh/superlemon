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

public enum FileOperationError: Error, Equatable, LocalizedError {
    case alreadyExists(String)
    case notFound(String)
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let path):
            return "An item already exists at \(path)."
        case .notFound(let path):
            return "No item exists at \(path)."
        case .invalidName(let name):
            return name.isEmpty
                ? "The item name cannot be empty."
                : "\u{201C}\(name)\u{201D} is not a valid item name."
        }
    }
}

public enum FileOperations {

    /// Creates an empty file `name` inside `directory`. Fails if it exists.
    @discardableResult
    public static func createFile(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(try validateName(name))
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
        let url = directory.appendingPathComponent(try validateName(name))
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw FileOperationError.alreadyExists(url.path)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames the item at `url` to `newName` within the same directory.
    ///
    /// Existence is checked with `lstat` (never following the final symlink
    /// component): `fileExists(atPath:)` reports a dangling symlink as
    /// absent, which would otherwise make a broken symlink row un-renameable.
    ///
    /// A destination that already exists is only a real collision if it
    /// names a *different* file. On a case-insensitive volume, `README.md`
    /// → `readme.md` resolves to the same inode — `fileExists` sees that as
    /// a pre-existing destination and would refuse the rename outright, so
    /// case-only renames are impossible without this check. When source and
    /// destination are the same file, hop through a temporary name in the
    /// same directory so `moveItem` sees two genuinely distinct paths at
    /// each step (its direct-rename behavior when source and destination
    /// differ only by case is filesystem-dependent).
    @discardableResult
    public static func rename(at url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(try validateName(newName))
        let fm = FileManager.default
        guard itemExists(at: url) else {
            throw FileOperationError.notFound(url.path)
        }
        guard itemExists(at: destination) else {
            try fm.moveItem(at: url, to: destination)
            return destination
        }
        guard isSameFile(url, destination) else {
            throw FileOperationError.alreadyExists(destination.path)
        }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".superlemon-rename-\(UUID().uuidString)")
        try fm.moveItem(at: url, to: temp)
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch {
            _ = try? fm.moveItem(at: temp, to: url)
            throw error
        }
        return destination
    }

    /// True when something exists at `url`, without following a final
    /// symlink component — so a dangling symlink still counts as present.
    static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// True when `a` and `b` are the same filesystem object (same device and
    /// inode) — the case-insensitive-volume case-only-rename check.
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        var infoA = stat()
        var infoB = stat()
        guard lstat(a.path, &infoA) == 0, lstat(b.path, &infoB) == 0 else { return false }
        return infoA.st_dev == infoB.st_dev && infoA.st_ino == infoB.st_ino
    }

    /// Moves the item to the Trash. A Trash failure is deliberately surfaced
    /// to the caller: a recoverable UI operation must never silently turn into
    /// permanent deletion.
    public static func trash(_ url: URL) throws {
        try trash(url) { candidate in
            try FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
        }
    }

    /// Injection seam used to prove that a failed Trash move leaves the
    /// original item untouched. Deliberately internal; callers use `trash(_:)`.
    static func trash(_ url: URL, moveToTrash: (URL) throws -> Void) throws {
        guard itemExists(at: url) else {
            throw FileOperationError.notFound(url.path)
        }
        try moveToTrash(url)
    }

    /// Applies a mutating operation. `.revealInFinder` is a no-op here
    /// (pure UI concern — the embedder calls NSWorkspace).
    @discardableResult
    public static func perform(_ operation: FileOperation) throws -> URL? {
        switch operation {
        case let .newFile(directory, name):
            return try createFile(in: URL(fileURLWithPath: directory), name: name)
        case let .newFolder(directory, name):
            return try createFolder(in: URL(fileURLWithPath: directory), name: name)
        case let .rename(path, newName):
            return try rename(at: URL(fileURLWithPath: path), to: newName)
        case let .trash(path):
            try trash(URL(fileURLWithPath: path))
            return nil
        case .revealInFinder:
            return nil
        }
    }

    /// Validates a single path component while preserving the user's exact
    /// spelling. Whitespace-only names and NUL/path separators are rejected
    /// before any filesystem mutation is attempted.
    public static func validateName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.contains("/"), !name.contains("\0"), name != ".", name != ".."
        else {
            throw FileOperationError.invalidName(name)
        }
        return name
    }
}
