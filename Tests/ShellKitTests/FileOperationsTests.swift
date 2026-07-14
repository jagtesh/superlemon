import Foundation
import Testing
@testable import ShellKit

@Suite("FileOperations")
struct FileOperationsTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellKitOps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: create

    @Test func createFileMakesEmptyFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try FileOperations.createFile(in: dir, name: "untitled.txt")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func createFileRefusesExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileOperations.createFile(in: dir, name: "a.txt")
        #expect(throws: FileOperationError.alreadyExists(
            dir.appendingPathComponent("a.txt").path
        )) {
            try FileOperations.createFile(in: dir, name: "a.txt")
        }
    }

    @Test func createFolderMakesDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try FileOperations.createFolder(in: dir, name: "sub")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    // MARK: rename

    @Test func renameMovesWithinDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = try FileOperations.createFile(in: dir, name: "old.txt")
        let renamed = try FileOperations.rename(at: original, to: "new.txt")

        #expect(renamed == dir.appendingPathComponent("new.txt"))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func renameRefusesCollisionAndMissingSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try FileOperations.createFile(in: dir, name: "a.txt")
        try FileOperations.createFile(in: dir, name: "b.txt")

        #expect(throws: FileOperationError.self) {
            try FileOperations.rename(at: a, to: "b.txt")
        }
        #expect(throws: FileOperationError.self) {
            try FileOperations.rename(at: dir.appendingPathComponent("ghost.txt"), to: "x.txt")
        }
    }

    @Test(arguments: ["", "   ", "a/b", "a\0b", ".", ".."])
    func invalidNamesAreRejected(name: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: FileOperationError.invalidName(name)) {
            try FileOperations.createFile(in: dir, name: name)
        }
    }

    @Test func performReturnsCreatedAndRenamedLocations() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let created = try FileOperations.perform(
            .newFile(directory: dir.path, name: "created.txt"))
        #expect(created == dir.appendingPathComponent("created.txt"))
        let renamed = try FileOperations.perform(
            .rename(path: created!.path, newName: "renamed.txt"))
        #expect(renamed == dir.appendingPathComponent("renamed.txt"))
    }

    // MARK: trash

    @Test func trashRemovesFileFromOriginalLocation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try FileOperations.createFile(in: dir, name: "doomed.txt")
        try FileOperations.trash(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func trashRemovesFolderRecursively() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = try FileOperations.createFolder(in: dir, name: "nest")
        try FileOperations.createFile(in: folder, name: "egg.txt")
        try FileOperations.trash(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func trashMissingItemThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: FileOperationError.self) {
            try FileOperations.trash(dir.appendingPathComponent("ghost.txt"))
        }
    }

    @Test func failedTrashMoveNeverFallsBackToPermanentDeletion() throws {
        enum SimulatedTrashFailure: Error { case unavailable }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try FileOperations.createFile(in: dir, name: "keep-me.txt")

        #expect(throws: SimulatedTrashFailure.self) {
            try FileOperations.trash(url) { _ in
                throw SimulatedTrashFailure.unavailable
            }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: perform (enum dispatch)

    @Test func performAppliesOperations() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileOperations.perform(.newFile(directory: dir.path, name: "f.txt"))
        try FileOperations.perform(.newFolder(directory: dir.path, name: "d"))
        try FileOperations.perform(.rename(path: dir.appendingPathComponent("f.txt").path,
                                           newName: "g.txt"))
        try FileOperations.perform(.trash(path: dir.appendingPathComponent("d").path))
        // revealInFinder is a UI concern — must be a no-op here.
        try FileOperations.perform(.revealInFinder(path: dir.path))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["g.txt"])
    }
}
