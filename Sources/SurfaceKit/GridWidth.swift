import GridKit

/// Grid-based double-width detection: no text classification needed, since
/// nvim already tells us the answer in the grid itself — a wide grapheme is
/// always followed by an empty-text placeholder cell (its trailing half).
extension Grid {
    /// True when the cell at (row, col) is the leading cell of a
    /// double-width glyph: its text is non-empty and the very next column
    /// in the same row exists and is empty.
    func isDoubleWidth(row: Int, col: Int) -> Bool {
        guard row >= 0, row < rows, col >= 0, col < cols else { return false }
        guard !self[row, col].text.isEmpty else { return false }
        let nextCol = col + 1
        guard nextCol < cols else { return false }
        return self[row, nextCol].text.isEmpty
    }
}
