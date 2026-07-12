// FileIndex — actor that walks a project root and serves the quick-open
// palette: full file list (modification-time ordered) and fuzzy queries via
// FuzzyScorer.
//
// Walking happens on the actor's executor (off the main thread). `.git` is
// always skipped. Root-level `.gitignore` rules are honored per the subset
// documented on `GitIgnoreRules`. The index caps at `maxFiles` (50 000)
// entries; refresh() re-walks from scratch.

import Foundation

public actor FileIndex {

    /// Default hard cap on indexed files.
    public static let defaultMaxFiles = 50_000

    public let root: URL
    /// Hard cap on indexed files (injectable for tests; 50k in production).
    public let maxFiles: Int

    /// Relative paths ordered by modification date, newest first.
    private var files: [String] = []

    public init(root: URL, maxFiles: Int = FileIndex.defaultMaxFiles) {
        self.root = root.standardizedFileURL
        self.maxFiles = maxFiles
    }

    /// All indexed relative paths, most recently modified first.
    public func allFiles() -> [String] { files }

    /// Number of indexed files (the live "32 files" count).
    public func count() -> Int { files.count }

    /// Re-walks the root directory, rebuilding the index.
    public func refresh() {
        let fm = FileManager.default
        let ignore = GitIgnoreRules(contentsOf: root.appendingPathComponent(".gitignore"))
        let rootPath = root.path

        var collected: [(path: String, mtime: Date)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [] // hidden files included; .gitignore decides, .git skipped below
        ) else {
            files = []
            return
        }

        for case let url as URL in enumerator {
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

            collected.append((relative, values?.contentModificationDate ?? .distantPast))
            if collected.count >= maxFiles { break }
        }

        collected.sort { lhs, rhs in
            lhs.mtime != rhs.mtime ? lhs.mtime > rhs.mtime : lhs.path < rhs.path
        }
        files = collected.map(\.path)
    }

    /// Fuzzy query over the index. Empty query returns the most recently
    /// modified files first; otherwise
    /// results are ranked by FuzzyScorer, best first.
    public func query(_ q: String, limit: Int = 50) -> [(path: String, positions: [Int])] {
        if q.isEmpty {
            return files.prefix(limit).map { ($0, []) }
        }
        var scored: [(path: String, positions: [Int], score: Double)] = []
        for path in files {
            if let (score, positions) = FuzzyScorer.score(query: q, candidate: path) {
                scored.append((path, positions, score))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        return scored.prefix(limit).map { ($0.path, $0.positions) }
    }

    private func relativePath(of path: String, under rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        var rel = String(path.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
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
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
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
