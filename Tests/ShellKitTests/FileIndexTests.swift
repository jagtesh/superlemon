import Foundation
import Testing
@testable import ShellKit

// MARK: - Fixture helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShellKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ relative: String, in root: URL, contents: String = "x") throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func setModificationDate(_ relative: String, in root: URL, _ date: Date) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: root.appendingPathComponent(relative).path
    )
}

@Suite("FileIndex")
struct FileIndexTests {

    @Test func indexesRegularFilesAndSkipsGitDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("main.swift", in: root)
        try write("src/app.js", in: root)
        try write(".git/config", in: root)
        try write(".git/objects/ab/cdef", in: root)

        let index = FileIndex(root: root)
        await index.refresh()
        let files = await index.allFiles()

        #expect(Set(files) == ["main.swift", "src/app.js"])
    }

    @Test func honorsRootGitignore() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(".gitignore", in: root, contents: """
        # build products
        build/
        *.log
        /secret.txt
        node_modules
        !keep.log
        """)
        try write("main.swift", in: root)
        try write("build/out.o", in: root)
        try write("debug.log", in: root)
        try write("nested/deep.log", in: root)
        try write("secret.txt", in: root)
        try write("sub/secret.txt", in: root)        // NOT ignored (rule anchored)
        try write("node_modules/pkg/index.js", in: root)
        try write("keep.log", in: root)              // negated back in

        let index = FileIndex(root: root)
        await index.refresh()
        let files = Set(await index.allFiles())

        #expect(files == [".gitignore", "main.swift", "sub/secret.txt", "keep.log"])
    }

    @Test func emptyQueryReturnsMostRecentlyModifiedFirst() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("old.txt", in: root)
        try write("middle.txt", in: root)
        try write("new.txt", in: root)
        let now = Date()
        try setModificationDate("old.txt", in: root, now.addingTimeInterval(-300))
        try setModificationDate("middle.txt", in: root, now.addingTimeInterval(-200))
        try setModificationDate("new.txt", in: root, now.addingTimeInterval(-100))

        let index = FileIndex(root: root)
        await index.refresh()
        let results = await index.query("")

        #expect(results.map(\.path) == ["new.txt", "middle.txt", "old.txt"])
        #expect(results.allSatisfy { $0.positions.isEmpty })

        let limited = await index.query("", limit: 2)
        #expect(limited.map(\.path) == ["new.txt", "middle.txt"])
    }

    @Test func queryRanksViaFuzzyScorerAndReturnsPositions() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("src/pages/index.astro", in: root)
        try write("index/other.css", in: root)
        try write("README.md", in: root)

        let index = FileIndex(root: root)
        await index.refresh()
        let results = await index.query("index")

        // Both index-ish files match; basename match ranks first; README
        // doesn't match at all.
        #expect(results.map(\.path) == ["src/pages/index.astro", "index/other.css"])
        let top = try #require(results.first)
        #expect(top.positions == [10, 11, 12, 13, 14])
    }

    @Test func countMatchesIndexedFiles() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.txt", in: root)
        try write("b.txt", in: root)

        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.count() == 2)
    }

    @Test func refreshPicksUpNewAndDeletedFiles() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.txt", in: root)

        let index = FileIndex(root: root)
        await index.refresh()
        #expect(await index.allFiles() == ["a.txt"])

        try write("b.txt", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        await index.refresh()
        #expect(await index.allFiles() == ["b.txt"])
    }

    @Test func capsAtMaxFiles() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<60 { try write("f\(i).txt", in: root) }

        // Same walk, cap injected low (production default is 50k).
        let capped = FileIndex(root: root, maxFiles: 25)
        await capped.refresh()
        #expect(await capped.count() == 25)

        let uncapped = FileIndex(root: root)
        await uncapped.refresh()
        #expect(await uncapped.count() == 60)
        #expect(FileIndex.defaultMaxFiles == 50_000)
    }
}

// MARK: - GitIgnoreRules (pure parser)

@Suite("GitIgnoreRules")
struct GitIgnoreRulesTests {

    @Test func skipsBlanksAndComments() {
        let rules = GitIgnoreRules("\n# comment\n\n  \n")
        #expect(rules.rules.isEmpty)
    }

    @Test(arguments: [
        ("*.log", "debug.log", false, true),
        ("*.log", "nested/deep.log", false, true),     // basename match at depth
        ("*.log", "logbook.txt", false, false),
        ("build/", "build", true, true),               // dir-only matches dir
        ("build/", "build", false, false),             // ...but not a file
        ("/secret.txt", "secret.txt", false, true),    // anchored
        ("/secret.txt", "sub/secret.txt", false, false),
        ("docs/*.md", "docs/a.md", false, true),       // slash → path match
        ("docs/*.md", "other/a.md", false, false),
        ("node_modules", "a/b/node_modules", true, true),
    ])
    func matching(pattern: String, path: String, isDirectory: Bool, expected: Bool) {
        let rules = GitIgnoreRules(pattern)
        #expect(rules.matches(path, isDirectory: isDirectory) == expected)
    }

    @Test func lastMatchingRuleWinsForNegation() {
        let rules = GitIgnoreRules("*.log\n!keep.log")
        #expect(rules.matches("debug.log", isDirectory: false))
        #expect(!rules.matches("keep.log", isDirectory: false))

        let reversed = GitIgnoreRules("!keep.log\n*.log")
        #expect(reversed.matches("keep.log", isDirectory: false))
    }
}
