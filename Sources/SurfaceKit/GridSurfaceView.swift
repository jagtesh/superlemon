import AppKit
import GridKit

/// Font + spacing configuration for the surface. `name == nil` means the
/// system monospaced font. Mirrors nvim's `guifont`/`linespace` (DESIGN §4).
public struct FontSpec: Sendable, Equatable {
    public var name: String?
    public var size: CGFloat
    public var linespace: CGFloat
    /// Synthesize Powerline separators/branch (U+E0A0, U+E0B0–B3) as vector
    /// shapes — works with ANY font, no patched font required.
    public var powerlineGlyphs: Bool
    /// Shape with the font's standard ligatures (=> ≠ etc. in fonts that
    /// have them); off forces per-character glyphs.
    public var ligatures: Bool
    /// Route symbols/ligatures through the bundled companion font
    /// (FiraCode Nerd Font Mono) — real calt ligatures + full Nerd glyph
    /// coverage with any text font. Off by default.
    public var useSymbolFont: Bool
    /// Force Superlemon's built-in fallback rendering (vector powerline
    /// shapes + Unicode ligature substitution) regardless of font support.
    public var forceSynthesis: Bool

    public init(
        name: String? = nil, size: CGFloat = 13, linespace: CGFloat = 0,
        powerlineGlyphs: Bool = false, ligatures: Bool = true,
        useSymbolFont: Bool = false, forceSynthesis: Bool = false
    ) {
        self.name = name
        self.size = size
        self.linespace = linespace
        self.powerlineGlyphs = powerlineGlyphs
        self.ligatures = ligatures
        self.useSymbolFont = useSymbolFont
        self.forceSynthesis = forceSynthesis
    }
}

/// The bridge component (DESIGN §5-6): a layer-hosting NSView that renders
/// GridKit flush snapshots via Core Text into per-grid CALayers.
///
/// Coordinates: the view is flipped — (row 0, col 0) is the top-left cell,
/// matching grid coordinates. All public geometry is in view coordinates.
///
/// PUBLIC API IS THE CONTRACT with SuperlemonApp — keep it source-compatible.
@MainActor
public final class GridSurfaceView: NSView {
    /// Pixel size of one grid cell for the current font. Changes only via
    /// `setFont`; the app derives resize geometry from it.
    public private(set) var cellSize: CGSize = .zero

    public private(set) var fontSpec: FontSpec

    public init(frame frameRect: NSRect, font: FontSpec) {
        self.fontSpec = font
        self.fonts = FontSet(spec: font)
        self.rasterizer = TextRasterizer(fonts: fonts)
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(cursorLayer)
        cellSize = fonts.cellSize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }

    /// Grid dimensions that fit the current bounds — feed to nvim_ui_try_resize.
    public var gridSize: (rows: Int, cols: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (0, 0) }
        return (
            rows: max(1, Int(bounds.height / cellSize.height)),
            cols: max(1, Int(bounds.width / cellSize.width))
        )
    }

    /// Present one atomic frame: apply scroll blits in order, repaint damaged
    /// spans, update layers and cursor — one CATransaction (DESIGN §5).
    public func present(_ flush: FlushResult) {
        lastFlush = flush
        commit(flush, redrawAll: false)
    }

    /// Change font/linespace (guifont path). Recomputes metrics and fully
    /// re-renders; the app follows up with nvim_ui_try_resize.
    public func setFont(_ spec: FontSpec) {
        fontSpec = spec
        fonts = FontSet(spec: spec)
        rasterizer = TextRasterizer(fonts: fonts)
        cellSize = fonts.cellSize
        renderers.removeAll()
        if let flush = lastFlush { commit(flush, redrawAll: true) }
    }

    /// Hit-test a view point to a (grid, row, col) cell for nvim_input_mouse.
    /// Multigrid frames resolve topmost-first; the outer grid is the fallback.
    public func cell(at point: NSPoint) -> (grid: Int, row: Int, col: Int)? {
        guard cellSize.width > 0, cellSize.height > 0, bounds.contains(point) else { return nil }
        let row = Int(point.y / cellSize.height)
        let col = Int(point.x / cellSize.width)
        for frame in lastFrames.reversed() {
            let r = frame.rect
            if row >= r.row, row < r.row + r.height, col >= r.col, col < r.col + r.width {
                return (grid: frame.gridID, row: row - r.row, col: col - r.col)
            }
        }
        return (grid: 1, row: row, col: col)
    }

    /// A grid's frame in view coordinates (top-left origin; the view is
    /// flipped). Nil for unknown/hidden grids. Used by the app to anchor
    /// chrome (popupmenu) at grid cells.
    public func rect(ofGrid id: Int) -> NSRect? {
        guard let frame = lastFrames.first(where: { $0.gridID == id }) else { return nil }
        return NSRect(
            x: CGFloat(frame.rect.col) * cellSize.width,
            y: CGFloat(frame.rect.row) * cellSize.height,
            width: CGFloat(frame.rect.width) * cellSize.width,
            height: CGFloat(frame.rect.height) * cellSize.height)
    }

    /// Convert a view point to a SPECIFIC grid's local cell, clamped to its
    /// bounds — mouse drags must stay on the press grid (`:h ui-multigrid`),
    /// even when the pointer wanders past its edges.
    public func cell(at point: NSPoint, inGrid id: Int) -> (row: Int, col: Int)? {
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        guard let frame = lastFrames.first(where: { $0.gridID == id }) else { return nil }
        let localRow = Int(floor(point.y / cellSize.height)) - frame.rect.row
        let localCol = Int(floor(point.x / cellSize.width)) - frame.rect.col
        return (
            row: max(0, min(frame.rect.height - 1, localRow)),
            col: max(0, min(frame.rect.width - 1, localCol))
        )
    }

    /// Cursor cell rect in view coordinates — the IME candidate-window anchor
    /// (NSTextInputClient firstRect). Nil while no flush has been presented.
    public var cursorRect: NSRect? {
        guard let flush = lastFlush, cellSize != .zero else { return nil }
        let origin = cursorOrigin(flush)
        return NSRect(origin: origin, size: cellSize)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let newScale = window?.backingScaleFactor ?? 2
        guard newScale != scale else { return }
        scale = newScale
        for renderer in renderers.values { renderer.setScale(newScale) }
        if let flush = lastFlush { commit(flush, redrawAll: true) }
    }

    // MARK: - internals

    private var fonts: FontSet
    private var rasterizer: TextRasterizer
    private var renderers: [Int: GridRenderer] = [:]
    private var gridLayers: [Int: CALayer] = [:]
    private let cursorLayer = CursorLayer()
    private var lastFlush: FlushResult?
    private var lastFrames: [ResolvedGridFrame] = []
    private var scale: CGFloat = 2

    private func commit(_ flush: FlushResult, redrawAll: Bool) {
        let outer = flush.grids[1]
        let frames = GridLayout.resolve(
            outerRows: outer?.rows ?? 0, outerCols: outer?.cols ?? 0,
            grids: flush.grids)
        lastFrames = frames

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layer?.backgroundColor = flush.highlights.defaultBackground.cgColor

        // 1. Update backing stores.
        var updatedContents: Set<Int> = []
        if redrawAll {
            for (id, grid) in flush.grids {
                renderer(for: id).apply(
                    grid: grid, damage: DamageMap(), highlights: flush.highlights)
                renderers[id]?.renderFullFromLastState()
                updatedContents.insert(id)
            }
        } else {
            for damaged in flush.damagedGrids {
                renderer(for: damaged.grid.id).apply(
                    grid: damaged.grid, damage: damaged.damage,
                    highlights: flush.highlights)
                updatedContents.insert(damaged.grid.id)
            }
        }

        // 2. Sync the layer tree to the resolved frames (back-to-front order).
        let cw = cellSize.width
        let ch = cellSize.height
        var visible: Set<Int> = []
        for frame in frames {
            guard flush.grids[frame.gridID] != nil else { continue }
            visible.insert(frame.gridID)
            let gridLayer = layerFor(frame.gridID, flush: flush, updated: &updatedContents)
            gridLayer.frame = CGRect(
                x: CGFloat(frame.rect.col) * cw,
                y: CGFloat(frame.rect.row) * ch,
                width: CGFloat(frame.rect.width) * cw,
                height: CGFloat(frame.rect.height) * ch)
            gridLayer.zPosition = CGFloat(frame.zIndex)
            if updatedContents.contains(frame.gridID) {
                gridLayer.contents = renderers[frame.gridID]?.image()
                gridLayer.contentsScale = scale
            }
        }

        // 3. Drop layers/renderers for grids that no longer exist; hidden
        //    grids keep their renderer but lose their layer.
        for (id, gridLayer) in gridLayers where !visible.contains(id) {
            gridLayer.removeFromSuperlayer()
            gridLayers.removeValue(forKey: id)
        }
        for id in renderers.keys where flush.grids[id] == nil {
            renderers.removeValue(forKey: id)
        }

        // 4. Cursor.
        cursorLayer.update(
            flush: flush, cellOrigin: cursorOrigin(flush),
            fonts: fonts, cache: rasterizer.cache, scale: scale)
    }

    private func renderer(for id: Int) -> GridRenderer {
        if let existing = renderers[id] { return existing }
        let created = GridRenderer(rasterizer: rasterizer, scale: scale)
        renderers[id] = created
        return created
    }

    /// Layer for a grid, created on demand. A grid that never appeared in
    /// damagedGrids (unlikely — creation damages everything) still gets a
    /// full render so its layer is never blank.
    private func layerFor(
        _ id: Int, flush: FlushResult, updated: inout Set<Int>
    ) -> CALayer {
        if let existing = gridLayers[id] { return existing }
        let created = CALayer()
        created.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
            "hidden": NSNull(), "zPosition": NSNull(),
        ]
        created.isOpaque = true
        created.contentsGravity = .topLeft
        gridLayers[id] = created
        layer?.addSublayer(created)
        if !updated.contains(id), let grid = flush.grids[id] {
            renderer(for: id).apply(
                grid: grid, damage: DamageMap(), highlights: flush.highlights)
            renderers[id]?.renderFullFromLastState()
            updated.insert(id)
        }
        return created
    }

    /// Cursor cell top-left in view coordinates (multigrid frame applied).
    private func cursorOrigin(_ flush: FlushResult) -> CGPoint {
        var row = flush.cursor.row
        var col = flush.cursor.col
        if let frame = lastFrames.first(where: { $0.gridID == flush.cursor.grid }) {
            row += frame.rect.row
            col += frame.rect.col
        }
        return CGPoint(x: CGFloat(col) * cellSize.width, y: CGFloat(row) * cellSize.height)
    }
}
