import Testing
@testable import ShellKit

@Suite("FuzzyScorer")
struct FuzzyScorerTests {

    private func score(_ query: String, _ candidate: String) -> Double? {
        FuzzyScorer.score(query: query, candidate: candidate)?.score
    }

    private func positions(_ query: String, _ candidate: String) -> [Int]? {
        FuzzyScorer.score(query: query, candidate: candidate)?.positions
    }

    // MARK: Matching basics

    @Test(arguments: [
        ("main", "main.swift"),
        ("msw", "main.swift"),
        ("idx", "src/pages/index.astro"),
        ("a", "a"),
    ])
    func matchesSubsequences(query: String, candidate: String) {
        #expect(score(query, candidate) != nil)
    }

    @Test(arguments: [
        ("xyz", "main.swift"),
        ("mains2", "main.swift"),   // out of order / missing
        ("aa", "a"),                // query longer than candidate
        ("swiftm", "main.swift"),   // subsequence order violated
    ])
    func rejectsNonMatches(query: String, candidate: String) {
        #expect(score(query, candidate) == nil)
    }

    @Test func emptyQueryMatchesEverythingWithZeroScore() {
        let result = FuzzyScorer.score(query: "", candidate: "anything/at/all.txt")
        #expect(result?.score == 0)
        #expect(result?.positions == [])
    }

    // MARK: Ranking properties

    @Test func exactBeatsPrefixBeatsScattered() throws {
        let exact = try #require(score("main", "main"))
        let prefix = try #require(score("main", "main.swift"))
        let scattered = try #require(score("main", "madrigal_intern.txt"))
        #expect(exact > prefix)
        #expect(prefix > scattered)
    }

    @Test func basenameMatchOutscoresDirectoryMatch() throws {
        let basename = try #require(score("index", "src/pages/index.astro"))
        let directory = try #require(score("index", "index/pages/other.astro"))
        #expect(basename > directory)
    }

    @Test func consecutiveRunBeatsScatteredMatch() throws {
        let consecutive = try #require(score("grid", "Sources/GridKit/grid.swift"))
        let scattered = try #require(score("grid", "Sources/GateRow/gui_raid.swift"))
        #expect(consecutive > scattered)
    }

    @Test func camelHumpMatchOutscoresMidWordMatch() throws {
        // "fs" hitting F + S humps of FuzzyScorer vs buried mid-word letters.
        let humps = try #require(score("fs", "FuzzyScorer.swift"))
        let buried = try #require(score("fs", "offsets.swift"))
        #expect(humps > buried)
    }

    @Test func separatorBonusPrefersWordStarts() throws {
        let wordStart = try #require(score("bar", "foo_bar.txt"))
        let midWord = try #require(score("bar", "rhubarb0.txt"))
        #expect(wordStart > midWord)
    }

    @Test func shorterCandidateWinsAtEqualQuality() throws {
        let short = try #require(score("app", "app.swift"))
        let long = try #require(score("app", "app_configuration_manager.swift"))
        #expect(short > long)
    }

    // MARK: Smart case

    @Test func lowercaseQueryIsCaseInsensitive() {
        #expect(score("readme", "README.md") != nil)
        #expect(score("fuzzy", "FuzzyScorer.swift") != nil)
    }

    @Test func uppercaseInQueryForcesCaseSensitivity() {
        #expect(score("README", "README.md") != nil)
        #expect(score("Readme", "README.md") == nil)  // no 'eadme' lowercase run
        #expect(score("FS", "FuzzyScorer.swift") != nil)
        #expect(score("FS", "offsets.swift") == nil)
    }

    // MARK: Positions

    @Test func exactMatchPositionsCoverWholeString() throws {
        let pos = try #require(positions("main", "main"))
        #expect(pos == [0, 1, 2, 3])
    }

    @Test func positionsAreAscendingAndPointAtQueryCharacters() throws {
        let query = "idx"
        let candidate = "src/pages/index.astro"
        let pos = try #require(positions(query, candidate))
        #expect(pos.count == query.count)
        #expect(pos == pos.sorted())
        #expect(Set(pos).count == pos.count)
        let chars = Array(candidate.lowercased())
        for (q, p) in zip(query, pos) {
            #expect(chars[p] == q)
        }
    }

    @Test func positionsPreferBasenameAlignment() throws {
        // Both "index" (dir) and "index" (basename) exist; the optimal
        // alignment should land on the basename run.
        let pos = try #require(positions("index", "index_old/index.astro"))
        #expect(pos == [10, 11, 12, 13, 14])
    }

    @Test func positionsPreferConsecutiveRuns() throws {
        let pos = try #require(positions("grid", "g_r_i_d_grid.swift"))
        #expect(pos == [8, 9, 10, 11])
    }

    // MARK: Guards

    @Test func overlongCandidateIsRejected() {
        let candidate = String(repeating: "a", count: 2000)
        #expect(score("aaa", candidate) == nil)
    }
}
