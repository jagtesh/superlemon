// FuzzyScorer — fzy-style subsequence scoring for the quick-open palette.
//
// Pure, nonisolated, no dependencies. Scores how well `query` matches
// `candidate` as a subsequence, returning nil when the query is not a
// subsequence at all. Higher scores are better. Also returns the matched
// character indices (into `candidate`) along the optimal alignment so the
// UI can bold them.
//
// Design (after https://github.com/jhawthorn/fzy):
//   - Dynamic programming over (query char × candidate char) with two
//     tables: best score ending in a match at j, and best score overall.
//   - Bonuses are precomputed per candidate position from the *previous*
//     character: path separator `/` > word separators `_ - . space` >
//     camelCase hump (lower→Upper) — plus the same word bonus at index 0.
//   - Consecutive matched characters earn a flat run bonus that beats any
//     positional bonus except the slash bonus.
//   - Gaps are penalized: leading/trailing gaps cheaply, inner gaps more,
//     so exact > prefix > scattered falls out of the math.
//   - Basename affinity: every matched character inside the path's
//     basename earns a small additive boost (applied on both match-start
//     and consecutive paths — a deliberate deviation from fzy), so basename
//     matches outscore directory matches AND the backtracked highlight
//     positions prefer the basename when the same run exists in both.
//   - Smart case: matching is case-insensitive unless the query contains
//     an uppercase letter, in which case it is case-sensitive.

public enum FuzzyScorer {

    // MARK: Tuning constants (fzy-derived)

    static let scoreGapLeading: Double = -0.005
    static let scoreGapTrailing: Double = -0.005
    static let scoreGapInner: Double = -0.01
    static let scoreMatchConsecutive: Double = 1.0
    static let scoreMatchSlash: Double = 0.9
    static let scoreMatchWord: Double = 0.8
    static let scoreMatchCapital: Double = 0.7
    static let scoreMatchDot: Double = 0.6
    /// Added for EVERY matched character that sits in the basename.
    static let scoreBasenamePerChar: Double = 0.1
    /// Score assigned to an exact (full-string) match; above anything the DP can produce.
    static let scoreMax: Double = .infinity
    /// Candidates longer than this are rejected (DP cost guard, as in fzy).
    static let maxCandidateLength = 1024

    /// Scores `query` against `candidate`.
    ///
    /// - Returns: `(score, positions)` where `positions` are indices into
    ///   `candidate`'s characters (ascending, one per query character), or
    ///   nil if `query` is not a subsequence of `candidate`. An empty query
    ///   matches everything with score 0 and no positions.
    public static func score(query: String, candidate: String) -> (score: Double, positions: [Int])? {
        if query.isEmpty { return (0, []) }

        let caseSensitive = query.contains(where: \.isUppercase) // smart case
        let q = Array(query)
        let c = Array(candidate)
        let n = q.count
        let m = c.count
        if n > m || m > maxCandidateLength { return nil }

        let qFold: [Character] = caseSensitive ? q : q.map(foldCase)
        let cFold: [Character] = caseSensitive ? c : c.map(foldCase)

        // Cheap subsequence pre-check.
        guard isSubsequence(qFold, of: cFold) else { return nil }

        if n == m {
            // Subsequence of equal length == exact match.
            return (scoreMax, Array(0..<m))
        }

        var bonus = matchBonuses(for: c)

        // Per-character basename boost. `basenameStart` is 0 for bare
        // filenames — every character of "a.txt" counts as basename.
        let basenameStart = cFold.lastIndex(of: "/").map { $0 + 1 } ?? 0
        var boost = [Double](repeating: 0, count: m)
        for j in basenameStart..<m {
            boost[j] = scoreBasenamePerChar
            bonus[j] += scoreBasenamePerChar
        }

        // DP tables. d[i][j]: best score of matching q[0...i] with q[i]
        // matched at c[j]. t[i][j]: best score of matching q[0...i]
        // considering c[0...j] (match at j or skip j).
        let negInf = -Double.infinity
        var d = [[Double]](repeating: [Double](repeating: negInf, count: m), count: n)
        var t = [[Double]](repeating: [Double](repeating: negInf, count: m), count: n)

        for i in 0..<n {
            let gapPenalty = (i == n - 1) ? scoreGapTrailing : scoreGapInner
            var prevScore = negInf
            for j in 0..<m {
                if qFold[i] == cFold[j] {
                    var gapScore = negInf
                    if i == 0 {
                        gapScore = Double(j) * scoreGapLeading + bonus[j]
                    } else if j > 0 {
                        let afterConsecutive = d[i - 1][j - 1] + scoreMatchConsecutive + boost[j]
                        let afterGap = t[i - 1][j - 1] + bonus[j]
                        gapScore = max(afterConsecutive, afterGap)
                    }
                    d[i][j] = gapScore
                    prevScore = max(gapScore, prevScore + gapPenalty)
                } else {
                    d[i][j] = negInf
                    prevScore += gapPenalty
                }
                t[i][j] = prevScore
            }
        }

        guard t[n - 1][m - 1] > negInf else { return nil }

        // Backtrack the optimal alignment for highlight positions.
        var positions = [Int](repeating: 0, count: n)
        var matchRequired = false
        var j = m - 1
        var i = n - 1
        while i >= 0 {
            while j >= 0 {
                if d[i][j] != negInf && (matchRequired || d[i][j] == t[i][j]) {
                    // Was this match a consecutive continuation? Then the
                    // previous query char MUST be matched at j-1.
                    matchRequired = i > 0 && j > 0
                        && t[i][j] == d[i - 1][j - 1] + scoreMatchConsecutive + boost[j]
                    positions[i] = j
                    j -= 1
                    break
                }
                j -= 1
            }
            i -= 1
        }

        return (t[n - 1][m - 1], positions)
    }

    // MARK: - Helpers

    private static func foldCase(_ ch: Character) -> Character {
        ch.isUppercase ? Character(ch.lowercased()) : ch
    }

    private static func isSubsequence(_ q: [Character], of c: [Character]) -> Bool {
        var qi = 0
        for ch in c where qi < q.count {
            if ch == q[qi] { qi += 1 }
        }
        return qi == q.count
    }

    /// Per-position match bonus derived from the preceding character.
    private static func matchBonuses(for c: [Character]) -> [Double] {
        var bonus = [Double](repeating: 0, count: c.count)
        var prev: Character = "/"  // treat index 0 like the char after a slash
        for (j, ch) in c.enumerated() {
            if prev == "/" {
                bonus[j] = scoreMatchSlash
            } else if prev == "-" || prev == "_" || prev == " " {
                bonus[j] = scoreMatchWord
            } else if prev == "." {
                bonus[j] = scoreMatchDot
            } else if prev.isLowercase && ch.isUppercase {
                bonus[j] = scoreMatchCapital  // camelCase hump
            }
            prev = ch
        }
        return bonus
    }
}
