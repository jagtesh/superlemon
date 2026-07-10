import Testing
import NvimKit
@testable import GridKit

/// A scripted redraw session simulating a realistic multigrid attach:
/// attach + two windows, then a scroll in one window, then a float —
/// asserting final cell content and cumulative damage exactly.
@MainActor
@Suite struct SessionTests {
    @Test func realisticRedrawSession() {
        let store = GridStore()

        // ---- Frame 1: attach — colors, highlights, modes, two windows -----
        var normal = ModeInfo()
        normal.name = "normal"
        normal.cursorShape = .block
        var insert = ModeInfo()
        insert.name = "insert"
        insert.cursorShape = .vertical

        var comment = HlAttrs()
        comment.foreground = rgb(0x888888)
        comment.italic = true
        var statusline = HlAttrs()
        statusline.reverse = true

        var events: [UIEvent] = [
            .setTitle("main.rs"),
            .defaultColorsSet(fg: rgb(0xDDDDDD), bg: rgb(0x1E1E1E), special: rgb(0xFF5555)),
            .hlAttrDefine(id: 1, attrs: comment),
            .hlAttrDefine(id: 2, attrs: statusline),
            .hlGroupSet(name: "Comment", id: 1),
            .hlGroupSet(name: "StatusLine", id: 2),
            .modeInfoSet(cursorStyleEnabled: true, modes: [normal, insert]),
            .modeChange(mode: "normal", modeIndex: 0),
            // Outer grid and two stacked windows (12-col wide for brevity).
            .gridResize(grid: 1, width: 12, height: 10),
            .gridResize(grid: 2, width: 12, height: 4),
            .winPos(grid: 2, win: 1000, startRow: 0, startCol: 0, width: 12, height: 4),
            .gridResize(grid: 3, width: 12, height: 4),
            .winPos(grid: 3, win: 1001, startRow: 5, startCol: 0, width: 12, height: 4),
        ]
        // Window 1 content: four numbered lines.
        events.append(line(2, 0, 0, runs("fn main() {")))
        events.append(line(2, 1, 0, [run(" ", rep: 2)] + runs("// hi", hl: 1)))
        events.append(line(2, 2, 0, runs("}")))
        events.append(line(2, 3, 0, [run("~", hl: 1), run(" ", rep: 11)]))
        // Statusline rows on grid 1.
        events.append(line(1, 4, 0, [run("=", hl: 2, rep: 12)]))
        events.append(line(1, 9, 0, [run("=", hl: 2, rep: 12)]))
        // Window 2 content: letters.
        events.append(line(3, 0, 0, runs("alpha")))
        events.append(line(3, 1, 0, runs("beta")))
        events.append(line(3, 2, 0, runs("gamma")))
        events.append(line(3, 3, 0, runs("delta")))
        events.append(.gridCursorGoto(grid: 2, row: 0, col: 0))
        events.append(.flush)

        let frame1 = store.apply(RedrawBatch(events: events))
        #expect(frame1 != nil)
        // All three grids fully damaged (fresh from grid_resize).
        #expect(frame1!.damagedGrids.map(\.grid.id) == [1, 2, 3])
        #expect(frame1!.damagedGrids[0].damage.rowSpans == fullDamage(rows: 10, cols: 12))
        #expect(frame1!.damagedGrids[1].damage.rowSpans == fullDamage(rows: 4, cols: 12))
        #expect(frame1!.damagedGrids[2].damage.rowSpans == fullDamage(rows: 4, cols: 12))
        #expect(frame1!.cursor == CursorPosition(grid: 2, row: 0, col: 0))
        #expect(frame1!.mode?.name == "normal")
        #expect(frame1!.title == "main.rs")
        #expect(store.grids[2]!.rowText(0) == "fn main() {")
        #expect(store.grids[2]![1, 2] == Cell(text: "/", hlID: 1))
        #expect(store.highlights.resolved(id: 2).foreground == rgb(0x1E1E1E)) // reverse
        #expect(store.highlights.resolved(id: 2).background == rgb(0xDDDDDD))

        // ---- Frame 2: scroll window 2 up one line, new bottom line --------
        let frame2 = store.apply(RedrawBatch(events: [
            .gridScroll(grid: 3, top: 0, bottom: 4, left: 0, right: 12, rows: 1, cols: 0),
            line(3, 3, 0, runs("epsilon")),
            .gridCursorGoto(grid: 3, row: 3, col: 0),
            .winViewport(grid: 3, win: 1001, topline: 1, botline: 5, curline: 4,
                         curcol: 0, lineCount: 20, scrollDelta: 1),
            .flush,
        ]))!

        // Only grid 3 was damaged this frame.
        #expect(frame2.damagedGrids.map(\.grid.id) == [3])
        let d3 = frame2.damagedGrids[0].damage
        #expect(d3.scrolls == [ScrollDelta(top: 0, bottom: 4, left: 0, right: 12, rows: 1, cols: 0)])
        // Cumulative dirty spans: exactly the exposed+rewritten bottom row.
        #expect(d3.rowSpans == [3: [0..<12]])
        #expect(store.grids[3]!.rowText(0) == "beta")
        #expect(store.grids[3]!.rowText(1) == "gamma")
        #expect(store.grids[3]!.rowText(2) == "delta")
        #expect(store.grids[3]!.rowText(3) == "epsilon")
        #expect(store.grids[3]!.viewport == Viewport(
            topline: 1, botline: 5, curline: 4, curcol: 0, lineCount: 20, scrollDelta: 1))
        #expect(frame2.cursor == CursorPosition(grid: 3, row: 3, col: 0))
        #expect(store.grids[3]!.hasCursor)
        #expect(!store.grids[2]!.hasCursor)

        // ---- Frame 3: open a float over window 1 ---------------------------
        let frame3 = store.apply(RedrawBatch(events: [
            .gridResize(grid: 5, width: 8, height: 2),
            .winFloatPos(grid: 5, win: 1002, anchor: "NW", anchorGrid: 2,
                         anchorRow: 1, anchorCol: 2, focusable: true, zIndex: 50),
            line(5, 0, 0, runs("Hover!")),
            line(5, 1, 0, [run(" ", rep: 8)]),
            .flush,
        ]))!

        #expect(frame3.damagedGrids.map(\.grid.id) == [5])
        #expect(frame3.damagedGrids[0].damage.rowSpans == fullDamage(rows: 2, cols: 8))
        #expect(frame3.damagedGrids[0].damage.scrolls.isEmpty)
        #expect(store.grids[5]!.rowText(0) == "Hover!")

        // Final layout: base grid, two windows, float on top; float frame is
        // window 1's frame (0,0) offset by the anchor (1,2).
        let frames = GridLayout.resolve(outerRows: 10, outerCols: 12, grids: store.grids)
        #expect(frames.map(\.gridID) == [1, 2, 3, 5])
        #expect(frames.last?.rect == GridRect(row: 1, col: 2, width: 8, height: 2))
        #expect(frames.last?.zIndex == GridLayout.floatZBase + 50)

        // Frame 4: no changes -> flush still returns, with nothing damaged.
        let frame4 = store.apply(RedrawBatch(events: [.flush]))!
        #expect(frame4.damagedGrids.isEmpty)

        // And a batch with no flush returns nil.
        #expect(store.apply(RedrawBatch(events: [.busyStart])) == nil)
    }
}
