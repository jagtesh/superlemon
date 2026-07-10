/// One grid cell: a grapheme cluster plus a highlight table index.
/// See DESIGN.md §4.
public struct Cell: Sendable, Equatable, Hashable {
    /// The grapheme cluster occupying this cell. An empty string means there
    /// is nothing to draw here: either the trailing half of a double-width
    /// cell (nvim sends those as empty-text cells after the wide grapheme),
    /// or a cell that has never been written since clear/resize.
    public var text: String
    /// Index into the highlight table. 0 is the default highlight.
    public var hlID: Int

    public init(text: String, hlID: Int) {
        self.text = text
        self.hlID = hlID
    }

    /// The value new/cleared cells take (nothing to draw, default highlight).
    public static let blank = Cell(text: "", hlID: 0)

    /// True when this cell draws nothing (blank or double-width trailing half).
    public var isEmpty: Bool { text.isEmpty }
}
