// Tests for SurfaceHostRouter (docs/design/surface-navbar-v1.md §7):
// - pure §6 wire decoders (render payload, open/close/host payloads,
//   callback replies) including malformed-input handling.
// - winid -> grid resolution and stale-seq drop logic in `sync(flush:)`,
//   driven through real GridStore flushes exactly like SurfaceKitTests does.
//
// CRITICAL: never orders a window onto the screen. TreeSurfaceView is only
// ever constructed off-screen by the router itself; nothing here calls
// makeKeyAndOrderFront/orderFront.

import AppKit
import GridKit
import NvimKit
import ShellKit
import Testing

@testable import EditorHostKit

/// Drive a GridStore with synthetic UI events and return the flush result,
/// mirroring SurfaceKitTests' helper of the same shape.
@MainActor
private func flush(_ store: GridStore, _ events: [UIEvent]) -> FlushResult {
    let result = store.apply(RedrawBatch(events: events + [.flush]))
    precondition(result != nil, "batch ended in flush; apply must return a result")
    return result!
}

private func map(_ pairs: [(String, Value)]) -> Value {
    .map(pairs.map { (.string($0.0), $0.1) })
}

// MARK: - Decoding

@MainActor
@Suite("SurfaceHostRouter wire decoding")
struct SurfaceHostRouterDecodingTests {
    @Test func decodesOpenPayload() {
        let args = map([
            ("surface_id", .string("navbar")), ("win", .int(7)), ("buf", .int(3)),
            ("event_cb", .int(11)),
        ])
        let decoded = SurfaceHostRouter.decodeOpenPayload(args)
        #expect(decoded?.surfaceID == "navbar")
        #expect(decoded?.win == 7)
        #expect(decoded?.buf == 3)
        #expect(decoded?.eventCb == 11)
    }

    @Test func dropsOpenPayloadMissingRequiredFields() {
        #expect(SurfaceHostRouter.decodeOpenPayload(map([("surface_id", .string("navbar"))])) == nil)
        #expect(SurfaceHostRouter.decodeOpenPayload(.nil) == nil)
        #expect(SurfaceHostRouter.decodeOpenPayload(.array([])) == nil)
    }

    @Test func decodesCloseAndHostPayloads() {
        #expect(
            SurfaceHostRouter.decodeCloseSurfaceID(map([("surface_id", .string("navbar"))]))
                == "navbar")
        #expect(SurfaceHostRouter.decodeCloseSurfaceID(map([])) == nil)
        #expect(
            SurfaceHostRouter.decodeHostPath(map([("path", .string("/tmp/x"))])) == "/tmp/x")
        #expect(SurfaceHostRouter.decodeHostPath(map([])) == nil)
    }

    @Test func decodesFullRenderPayload() throws {
        let args = map([
            ("surface_id", .string("navbar")),
            ("seq", .int(2)),
            ("header", map([("title", .string("myproject"))])),
            (
                "menu",
                .array([
                    map([
                        ("id", .string("new_file")), ("title", .string("New File")),
                        ("for_kinds", .array([.string("file"), .string("dir"), .string("root")])),
                    ])
                ])
            ),
            (
                "rows",
                .array([
                    map([
                        ("id", .string("/proj/Sources")), ("label", .string("Sources")),
                        ("depth", .int(0)), ("kind", .string("dir")),
                        ("expanded", .bool(true)),
                        ("dot", .string("#61afef")),
                    ]),
                    map([
                        ("id", .string("/proj/Sources/main.swift")),
                        ("label", .string("main.swift")),
                        ("depth", .int(1)), ("kind", .string("file")),
                        ("badge", map([("text", .string("M")), ("color", .string("#e5c07b"))])),
                    ]),
                ])
            ),
        ])

        let decoded = SurfaceHostRouter.decodeRenderModel(args)
        #expect(decoded?.seq == 2)
        let model = try #require(decoded?.model)
        #expect(model.seq == 2)
        #expect(model.headerTitle == "myproject")
        #expect(model.menu == [
            TreeSurfaceMenuItem(
                id: "new_file", title: "New File", forKinds: ["file", "dir", "root"])
        ])
        #expect(model.rows.count == 2)
        #expect(model.rows[0].id == "/proj/Sources")
        #expect(model.rows[0].kind == .dir)
        #expect(model.rows[0].expanded == true)
        #expect(model.rows[0].dotColorHex == "#61afef")
        #expect(model.rows[1].kind == .file)
        #expect(model.rows[1].badge == TreeSurfaceBadge(text: "M", colorHex: "#e5c07b"))
    }

    @Test func renderPayloadDefaultsMissingHeaderAndMenu() {
        let args = map([
            ("seq", .int(1)),
            ("rows", .array([])),
        ])
        let decoded = SurfaceHostRouter.decodeRenderModel(args)
        #expect(decoded?.model.headerTitle == "")
        #expect(decoded?.model.menu == [])
        #expect(decoded?.model.rows == [])
    }

    @Test func dropsRenderPayloadMissingSeqOrRows() {
        #expect(SurfaceHostRouter.decodeRenderModel(map([("rows", .array([]))])) == nil)
        #expect(SurfaceHostRouter.decodeRenderModel(map([("seq", .int(1))])) == nil)
        #expect(SurfaceHostRouter.decodeRenderModel(.nil) == nil)
    }

    @Test func skipsMalformedMenuItemsButKeepsTheWholePayload() throws {
        let args = map([
            ("seq", .int(1)),
            (
                "menu",
                .array([
                    map([("id", .string("rename"))]),  // missing title: dropped
                    map([("id", .string("delete")), ("title", .string("Move to Trash"))]),
                ])
            ),
            (
                "rows",
                .array([
                    map([
                        ("id", .string("/b")), ("label", .string("b")), ("depth", .int(0)),
                        ("kind", .string("up")),
                    ])
                ])
            ),
        ])
        let decoded = try #require(SurfaceHostRouter.decodeRenderModel(args))
        #expect(decoded.model.menu.count == 1)
        #expect(decoded.model.menu[0].id == "delete")
        #expect(decoded.model.rows.count == 1)
    }

    /// `rows[i] == buffer line i` is the projection invariant — a render
    /// containing ANY malformed row is rejected outright rather than
    /// silently shifting every subsequent index (which would desync
    /// selection from the vim cursor).
    @Test func rejectsRenderContainingAnyMalformedRow() {
        let args = map([
            ("seq", .int(1)),
            (
                "rows",
                .array([
                    map([("id", .string("/a")), ("label", .string("a"))]),  // missing kind/depth
                    map([
                        ("id", .string("/b")), ("label", .string("b")), ("depth", .int(0)),
                        ("kind", .string("up")),
                    ]),
                ])
            ),
        ])
        #expect(SurfaceHostRouter.decodeRenderModel(args) == nil)
    }

    @Test func decodesCallbackReplies() {
        #expect(SurfaceHostRouter.decodeCallbackError(nil) == "no response")
        #expect(SurfaceHostRouter.decodeCallbackError(map([("ok", .bool(true))])) == nil)
        #expect(
            SurfaceHostRouter.decodeCallbackError(map([("error", .string("name taken"))]))
                == "name taken")
    }
}

// MARK: - Lifecycle: winid -> grid resolution, stale-seq drop, inferred close

@MainActor
@Suite("SurfaceHostRouter lifecycle", .serialized)
struct SurfaceHostRouterLifecycleTests {
    private func openArgs(win: Int = 42, eventCb: Int = 1) -> Value {
        map([
            ("surface_id", .string("navbar")), ("win", .int(Int64(win))),
            ("buf", .int(1)), ("event_cb", .int(Int64(eventCb))),
        ])
    }

    private func renderArgs(seq: Int) -> Value {
        map([
            ("surface_id", .string("navbar")), ("seq", .int(Int64(seq))),
            ("rows", .array([])),
        ])
    }

    @Test func mapsWinToGridSuppressesItAndSyncsSelectionAndActiveState() {
        let router = SurfaceHostRouter(controller: nil)
        var overlaidHandles: [Set<Int>] = []
        var requestedGridIDs: [Int] = []
        router.setOverlaidWindowHandles = { overlaidHandles.append($0) }
        router.overlayFrame = { gridID in
            requestedGridIDs.append(gridID)
            return NSRect(x: 0, y: 0, width: 200, height: 400)
        }
        var mounted: NSView?
        router.mountOverlay = { mounted = $0 }

        #expect(router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs()))
        #expect(router.isActive)
        #expect(mounted === router.treeView)

        let store = GridStore()
        let result = flush(store, [
            .gridResize(grid: 1, width: 80, height: 24),
            .gridResize(grid: 2, width: 32, height: 24),
            .winPos(grid: 2, win: 42, startRow: 0, startCol: 0, width: 32, height: 24),
            .gridCursorGoto(grid: 2, row: 0, col: 0),
            .winViewport(
                grid: 2, win: 42, topline: 0, botline: 24, curline: 3, curcol: 0,
                lineCount: 40, scrollDelta: 0),
        ])
        router.sync(flush: result)

        #expect(overlaidHandles.last == [42])
        #expect(requestedGridIDs.last == 2)
        #expect(router.treeView?.frame == NSRect(x: 0, y: 0, width: 200, height: 400))
        #expect(router.treeView?.isHidden == false)
        #expect(router.treeView?.selectedRow == 3)
    }

    @Test func overlayStaysHiddenUntilTheGridAppears() {
        let router = SurfaceHostRouter(controller: nil)
        router.setOverlaidWindowHandles = { _ in }
        router.mountOverlay = { _ in }
        _ = router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs(win: 99))

        // A flush that never mentions window 99 at all (the open notification
        // raced the first flush).
        let store = GridStore()
        let result = flush(store, [.gridResize(grid: 1, width: 80, height: 24)])
        router.sync(flush: result)

        #expect(router.isActive)
        #expect(router.treeView?.isHidden == true)
    }

    @Test func staleRenderSequenceIsDropped() {
        let router = SurfaceHostRouter(controller: nil)
        router.setOverlaidWindowHandles = { _ in }
        router.mountOverlay = { _ in }
        _ = router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs())

        #expect(router.handle(component: "surface", method: "render", namespace: "navbar", args: renderArgs(seq: 5)))
        #expect(router.treeView?.model?.seq == 5)

        // An older/equal seq must not clobber the newer applied model.
        _ = router.handle(component: "surface", method: "render", namespace: "navbar", args: renderArgs(seq: 3))
        #expect(router.treeView?.model?.seq == 5)
        _ = router.handle(component: "surface", method: "render", namespace: "navbar", args: renderArgs(seq: 5))
        #expect(router.treeView?.model?.seq == 5)

        // A genuinely newer seq applies.
        _ = router.handle(component: "surface", method: "render", namespace: "navbar", args: renderArgs(seq: 6))
        #expect(router.treeView?.model?.seq == 6)
    }

    @Test func renderBeforeOpenIsStashedAndAppliedOnMount() {
        let router = SurfaceHostRouter(controller: nil)
        router.setOverlaidWindowHandles = { _ in }
        router.mountOverlay = { _ in }

        #expect(router.treeView == nil)
        _ = router.handle(component: "surface", method: "render", namespace: "navbar", args: renderArgs(seq: 4))
        #expect(router.treeView == nil, "render before open must not create a view")

        _ = router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs())
        #expect(router.treeView?.model?.seq == 4)
    }

    @Test func explicitCloseUnmountsAndClearsSuppression() {
        let router = SurfaceHostRouter(controller: nil)
        var overlaidHandles: [Set<Int>] = []
        router.setOverlaidWindowHandles = { overlaidHandles.append($0) }
        var unmounted: NSView?
        router.mountOverlay = { _ in }
        router.unmountOverlay = { unmounted = $0 }

        _ = router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs())
        let view = router.treeView
        _ = router.handle(
            component: "surface", method: "close", namespace: "navbar",
            args: map([("surface_id", .string("navbar"))]))

        #expect(!router.isActive)
        #expect(router.treeView == nil)
        #expect(unmounted === view)
        #expect(overlaidHandles.last == [])
    }

    @Test func windowClosingWithoutAnExplicitCloseNotificationIsInferred() {
        let router = SurfaceHostRouter(controller: nil)
        var overlaidHandles: [Set<Int>] = []
        router.setOverlaidWindowHandles = { overlaidHandles.append($0) }
        router.overlayFrame = { _ in NSRect(x: 0, y: 0, width: 10, height: 10) }
        router.mountOverlay = { _ in }
        _ = router.handle(component: "surface", method: "open", namespace: "navbar", args: openArgs(win: 7))

        let store = GridStore()
        let opened = flush(store, [
            .gridResize(grid: 1, width: 80, height: 24),
            .gridResize(grid: 2, width: 32, height: 24),
            .winPos(grid: 2, win: 7, startRow: 0, startCol: 0, width: 32, height: 24),
        ])
        router.sync(flush: opened)
        #expect(router.isActive)

        let closed = flush(store, [.gridDestroy(grid: 2)])
        router.sync(flush: closed)

        #expect(!router.isActive)
        #expect(router.treeView == nil)
        #expect(overlaidHandles.last == [])
    }
}
