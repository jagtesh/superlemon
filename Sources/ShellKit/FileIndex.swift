// FileIndex — actor that lists a project root and serves the quick-open
// palette: full file list (modification-time ordered) and fuzzy queries via
// FuzzyScorer.
//
// Enumeration goes through a `WorkspaceIndexSource` (off the main thread).
// The local source walks FileManager: `.git` is always skipped and
// root-level `.gitignore` rules are honored per the subset documented on
// `GitIgnoreRules`. The index caps at `maxFiles` (50 000) entries;
// refresh() re-lists from scratch.

import Foundation

/// One indexable file: a root-relative path plus its modification time
/// (recency drives the empty-query ordering).
public struct WorkspaceIndexEntry: Sendable {
    public let path: String
    public let mtime: Date

    public init(path: String, mtime: Date) {
        self.path = path
        self.mtime = mtime
    }
}

public struct WorkspaceIndexListing: Sendable {
    public let entries: [WorkspaceIndexEntry]
    /// True when the enumeration found more files than the requested cap.
    public let isTruncated: Bool

    public init(entries: [WorkspaceIndexEntry], isTruncated: Bool) {
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

/// Enumerates every indexable file under a project root. The local source
/// walks FileManager; a session-backed source may read the filesystem the
/// connected editor actually sees, which need not be this machine's. A
/// thrown error (including CancellationError) leaves the previous index
/// intact rather than publishing a partial listing.
public protocol WorkspaceIndexSource: Sendable {
    func listFiles(root: URL, maxFiles: Int) async throws -> WorkspaceIndexListing
}

/// The local-filesystem walk (the production default and the fast path).
public struct LocalWorkspaceIndexSource: WorkspaceIndexSource {
    public init() {}

    public func listFiles(root: URL, maxFiles: Int) async throws -> WorkspaceIndexListing {
        // NSEnumerator iteration is unavailable in async contexts; the walk
        // itself is synchronous (cancellation is polled per item).
        try walk(root: root, maxFiles: maxFiles)
    }

    private func walk(root: URL, maxFiles: Int) throws -> WorkspaceIndexListing {
        let fm = FileManager.default
        let ignore = GitIgnoreRules(contentsOf: root.appendingPathComponent(".gitignore"))
        let rootPath = root.path

        var collected: [WorkspaceIndexEntry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [] // hidden files included; .gitignore decides, .git skipped below
        ) else {
            return WorkspaceIndexListing(entries: [], isTruncated: false)
        }

        var truncated = false
        for case let url as URL in enumerator {
            // A superseded refresh should leave the last complete index
            // intact instead of publishing a partial walk.
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let relative = relativePath(of: url.standardizedFileURL.path, under: rootPath)

            if isDirectory {
                if url.lastPathComponent == ".git" || ignore.matches(relative, isDirectory: true) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile ?? false else { continue }
            if ignore.matches(relative, isDirectory: false) { continue }

            collected.append(WorkspaceIndexEntry(
                path: relative,
                mtime: values?.contentModificationDate ?? .distantPast))
            // Read one item beyond the cap so the UI can distinguish exactly
            // `maxFiles` files from a truncated index.
            if collected.count > maxFiles {
                collected.removeLast()
                truncated = true
                break
            }
        }
        return WorkspaceIndexListing(entries: collected, isTruncated: truncated)
    }

    private func relativePath(of path: String, under rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        var rel = String(path.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}

public struct FileIndexQueryResult: Sendable {
    public let matches: [(path: String, positions: [Int])]
    /// Total matches before the display limit is applied.
    public let matchingCount: Int
    public let totalCount: Int
    public let isTruncated: Bool

    public init(
        matches: [(path: String, positions: [Int])],
        matchingCount: Int,
        totalCount: Int,
        isTruncated: Bool
    ) {
        self.matches = matches
        self.matchingCount = matchingCount
        self.totalCount = totalCount
        self.isTruncated = isTruncated
    }
}

public actor FileIndex {

    /// Default hard cap on indexed files.
    public static let defaultMaxFiles = 50_000

    public let root: URL
    /// Hard cap on indexed files (injectable for tests; 50k in production).
    public let maxFiles: Int
    private let source: WorkspaceIndexSource

    /// Relative paths ordered by modification date, newest first.
    private var files: [String] = []
    /// True when the last completed listing found more files than `maxFiles`.
    public private(set) var isTruncated = false

    public init(
        root: URL,
        maxFiles: Int = FileIndex.defaultMaxFiles,
        source: WorkspaceIndexSource = LocalWorkspaceIndexSource()
    ) {
        self.root = root.standardizedFileURL
        self.maxFiles = max(0, maxFiles)
        self.source = source
    }

    /// All indexed relative paths, most recently modified first.
    public func allFiles() -> [String] { files }

    /// Number of indexed files (the live "32 files" count).
    public func count() -> Int { files.count }

    /// Re-lists the root directory, rebuilding the index. A cancelled or
    /// failed listing (e.g. the session-backed source without a live
    /// session) leaves the last complete index intact.
    public func refresh() async {
        guard let listing = try? await source.listFiles(root: root, maxFiles: maxFiles),
            !Task.isCancelled
        else { return }
        var collected = listing.entries
        collected.sort { lhs, rhs in
            lhs.mtime != rhs.mtime ? lhs.mtime > rhs.mtime : lhs.path < rhs.path
        }
        files = collected.map(\.path)
        isTruncated = listing.isTruncated
    }

    /// Fuzzy query over the index. Empty query returns the most recently
    /// modified files first; otherwise
    /// results are ranked by FuzzyScorer, best first.
    public func query(_ q: String, limit: Int = 50) -> [(path: String, positions: [Int])] {
        rankedQuery(q, limit: limit).matches
    }

    private func rankedQuery(
        _ q: String, limit: Int
    ) -> (matches: [(path: String, positions: [Int])], matchingCount: Int) {
        let retainedLimit = max(0, limit)
        if q.isEmpty {
            return (files.prefix(retainedLimit).map { ($0, []) }, files.count)
        }
        typealias Scored = (path: String, positions: [Int], score: Double)
        // A worst-at-root bounded heap keeps memory at O(limit) and makes
        // every retained insertion O(log limit), instead of sorting all
        // project matches or shifting an O(limit) sorted array per match.
        var heap: [Scored] = []
        heap.reserveCapacity(min(retainedLimit, files.count))
        var matchingCount = 0

        @inline(__always)
        func ranksBefore(_ lhs: Scored, _ rhs: Scored) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }

        @inline(__always)
        func isWorse(_ lhs: Scored, than rhs: Scored) -> Bool {
            ranksBefore(rhs, lhs)
        }

        func siftUp(_ index: Int, in heap: inout [Scored]) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(heap[child], than: heap[parent]) else { return }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        func siftDown(_ index: Int, in heap: inout [Scored]) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                let right = left + 1
                var worstChild = left
                if right < heap.count, isWorse(heap[right], than: heap[left]) {
                    worstChild = right
                }
                guard isWorse(heap[worstChild], than: heap[parent]) else { return }
                heap.swapAt(parent, worstChild)
                parent = worstChild
            }
        }

        for (offset, path) in files.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return ([], 0) }
            if let (score, positions) = FuzzyScorer.score(query: q, candidate: path) {
                matchingCount += 1
                guard retainedLimit > 0 else { continue }
                let candidate: Scored = (path, positions, score)
                if heap.count < retainedLimit {
                    heap.append(candidate)
                    siftUp(heap.count - 1, in: &heap)
                } else if let worst = heap.first, ranksBefore(candidate, worst) {
                    heap[0] = candidate
                    siftDown(0, in: &heap)
                }
            }
        }
        heap.sort(by: ranksBefore)
        return (heap.map { ($0.path, $0.positions) }, matchingCount)
    }

    /// One actor hop for Quick Open: results and count/truncation metadata are
    /// guaranteed to describe the same completed index generation.
    public func search(_ q: String, limit: Int = 50) -> FileIndexQueryResult {
        let ranked = rankedQuery(q, limit: limit)
        return FileIndexQueryResult(
            matches: ranked.matches,
            matchingCount: ranked.matchingCount,
            totalCount: files.count,
            isTruncated: isTruncated)
    }
}

// MARK: - .gitignore subset

/// Parses the ROOT `.gitignore` only, supporting a documented subset:
///
/// - Blank lines and `#` comment lines are skipped.
/// - `!pattern` negates (re-includes); the LAST matching rule wins.
/// - A trailing `/` makes the rule directory-only.
/// - A pattern containing a `/` (other than trailing) is anchored to the
///   repository root and matched against the full relative path; a leading
///   `/` is the explicit form of the same anchoring.
/// - A pattern without `/` matches the basename at any depth.
/// - Wildcards use fnmatch(3) semantics: `*`, `?`, `[...]`. `*` may cross
///   `/` in anchored patterns (FNM_PATHNAME is NOT set) — close enough for
///   typical ignore files.
///
/// NOT supported by the current index (see DESIGN §14.4): `**` semantics
/// beyond what plain fnmatch gives, nested .gitignore files,
/// `.git/info/exclude`, global core.excludesFile, escaping (`\#`, `\!`),
/// and trailing-space quirks.
struct GitIgnoreRules {

    struct Rule {
        let pattern: String
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool // match against full relative path, not basename
    }

    private(set) var rules: [Rule] = []

    init(contentsOf url: URL) {
        self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    init(_ text: String) {
        // `split(separator: "\n")` looks for the lone Character "\n", but
        // Swift's grapheme-cluster rules fuse a "\r\n" pair into a single
        // Character distinct from "\n" — so a CRLF-saved .gitignore (common
        // from Windows tooling, or editors that preserve line endings)
        // would never split into lines at all. `\.isNewline` matches CR,
        // LF, and the fused CRLF cluster alike.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            }

            var directoryOnly = false
            if line.hasSuffix("/") {
                directoryOnly = true
                line.removeLast()
            }

            var anchored = line.contains("/")
            if line.hasPrefix("/") {
                anchored = true
                line.removeFirst()
            }
            if line.isEmpty { continue }

            rules.append(Rule(pattern: line, negated: negated,
                              directoryOnly: directoryOnly, anchored: anchored))
        }
    }

    /// True when `relativePath` should be ignored. Last matching rule wins.
    func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
        guard !relativePath.isEmpty else { return false }
        let basename = (relativePath as NSString).lastPathComponent
        var ignored = false
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            let target = rule.anchored ? relativePath : basename
            if fnmatchMatches(pattern: rule.pattern, string: target) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    private func fnmatchMatches(pattern: String, string: String) -> Bool {
        pattern.withCString { p in
            string.withCString { s in
                fnmatch(p, s, 0) == 0
            }
        }
    }
}
