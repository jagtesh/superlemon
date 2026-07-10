import NvimKit
@testable import GridKit

// Shared helpers for GridKit tests.

@MainActor
func makeStore(rows: Int = 10, cols: Int = 20) -> GridStore {
    let store = GridStore()
    _ = store.apply(RedrawBatch(events: [
        .gridResize(grid: 1, width: cols, height: rows),
        .flush,
    ]))
    return store
}

func batch(_ events: UIEvent...) -> RedrawBatch {
    RedrawBatch(events: events)
}

func line(_ grid: Int, _ row: Int, _ colStart: Int, _ cells: [CellRun]) -> UIEvent {
    .gridLine(grid: grid, row: row, colStart: colStart, cells: cells, wrap: false)
}

func run(_ text: String, hl: Int = 0, rep: Int = 1) -> CellRun {
    CellRun(text: text, hlID: hl, repeatCount: rep)
}

/// One single-cell run per character, all with the same highlight.
func runs(_ s: String, hl: Int = 0) -> [CellRun] {
    s.map { CellRun(text: String($0), hlID: hl) }
}

func rgb(_ v: UInt32) -> RGBColor { RGBColor(rgb: v) }

/// Full-grid damage expectation: every row dirty across `cols`.
func fullDamage(rows: Int, cols: Int) -> [Int: [Range<Int>]] {
    Dictionary(uniqueKeysWithValues: (0..<rows).map { ($0, [0..<cols]) })
}
