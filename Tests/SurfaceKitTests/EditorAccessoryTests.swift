import AppKit
import GridKit
import NvimKit
import Testing

@testable import SurfaceKit

private let accessoryFont = FontSpec(name: "Menlo", size: 13)

@MainActor
private func accessoryFlush(
    _ store: GridStore, _ events: [UIEvent]
) -> FlushResult {
    let result = store.apply(RedrawBatch(events: events + [.flush]))
    precondition(result != nil)
    return result!
}

@MainActor
private struct AccessoryHarness {
    let view: GridSurfaceView
    let store: GridStore
    let outerCols: Int
    let outerRows: Int
    let windowHandle: Int

    init(outerCols: Int = 100, outerRows: Int = 20, windowHandle: Int = 20) {
        view = GridSurfaceView(frame: .zero, font: accessoryFont)
        store = GridStore()
        self.outerCols = outerCols
        self.outerRows = outerRows
        self.windowHandle = windowHandle
        view.frame = CGRect(
            x: 0, y: 0,
            width: CGFloat(outerCols) * view.cellSize.width,
            height: CGFloat(outerRows) * view.cellSize.height)
        view.setMinimapTopologies([MinimapBufferTopology(
            windowHandle: windowHandle, bufferHandle: 44,
            changedTick: 1, totalLineCount: 2_000,
            highlightGeneration: 1)])
    }

    func presentInitial() {
        view.present(accessoryFlush(store, [
            .gridResize(grid: 1, width: outerCols, height: outerRows),
            .gridResize(grid: 2, width: outerCols, height: outerRows),
            .winPos(
                grid: 2, win: windowHandle, startRow: 0, startCol: 0,
                width: outerCols, height: outerRows),
            .gridCursorGoto(grid: 2, row: 4, col: 2),
            .winViewport(
                grid: 2, win: windowHandle, topline: 100,
                botline: 100 + outerRows, curline: 104, curcol: 2,
                lineCount: 2_000, scrollDelta: 0),
        ]))
    }

    func acknowledge(_ request: GridAccessorySizeRequest) {
        view.present(accessoryFlush(store, [
            .gridResize(grid: 2, width: request.cols, height: request.rows),
        ]))
    }
}

@Suite struct GridAccessoryPolicyTests {
    @Test func minimapThresholdUsesHysteresis() {
        let cellWidth: CGFloat = 8
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth - 0.5,
            cellWidth: cellWidth, innerRows: 14, wasWanted: false))
        #expect(GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth,
            cellWidth: cellWidth, innerRows: 14, wasWanted: false))
        #expect(GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 36 * cellWidth,
            cellWidth: cellWidth, innerRows: 10, wasWanted: true))
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 36 * cellWidth - 0.5,
            cellWidth: cellWidth, innerRows: 10, wasWanted: true))
        #expect(!GridAccessoryPolicy.wantsMinimap(
            outerWidth: 88 + 40 * cellWidth,
            cellWidth: cellWidth, innerRows: 9, wasWanted: true))
    }

    @Test func requestedRangeIsSlidingAndBounded() {
        let display = GridAccessoryPolicy.displayRange(
            totalLines: 100_000, viewportTopline: 50_000,
            railHeight: 600, scale: 2)
        let request = GridAccessoryPolicy.requestedRange(
            totalLines: 100_000, displayRange: display)
        #expect(request.count <= GridAccessoryPolicy.maximumChunkLines)
        #expect(request.lowerBound <= display.lowerBound)
        #expect(request.upperBound >= display.upperBound)
        #expect(request.lowerBound > 0)
        #expect(request.upperBound < 100_000)
    }

    @Test func sublimeTargetingCentersClicksAndPreservesDragGrabOffset() {
        #expect(GridAccessoryPolicy.targetTopline(
            clickedLine: 500, visibleLineCount: 40,
            grabOffsetLines: 20, totalLines: 1_000) == 480)
        #expect(GridAccessoryPolicy.targetTopline(
            clickedLine: 500, visibleLineCount: 40,
            grabOffsetLines: 7, totalLines: 1_000) == 493)
        #expect(GridAccessoryPolicy.targetTopline(
            clickedLine: 995, visibleLineCount: 40,
            grabOffsetLines: 7, totalLines: 1_000) == 960)
    }
}

@MainActor
@Suite struct GridAccessoryLifecycleTests {
    @Test func topologyPublishedAfterInitialFlushRequestsSizeImmediately() {
        let harness = AccessoryHarness()
        harness.view.removeMinimapTopology(windowHandle: harness.windowHandle)
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        #expect(requests.isEmpty)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.gutterFrame == nil)

        harness.view.updateMinimapTopology(MinimapBufferTopology(
            windowHandle: harness.windowHandle, bufferHandle: 44,
            changedTick: 2, totalLineCount: 2_000,
            highlightGeneration: 2))
        #expect(requests.count == 1,
                "publishing topology must re-evaluate the last flush")
        #expect(requests[0].releasesOwnership == false)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.gutterFrame == nil,
            "the gutter still waits for grid_resize acknowledgement")
    }

    @Test func publicGeometryConfigurationDrivesTheResizeContract() {
        let harness = AccessoryHarness()
        #expect(harness.view.minimapWidth == 88)
        #expect(harness.view.minimapScale == 0.20)
        #expect(harness.view.minimapPitch == 3.0)
        #expect(harness.view.minimapMinEditorColumns == 40)
        harness.view.minimapWidth = 104
        harness.view.minimapScale = 0.25
        harness.view.minimapPitch = 2.5
        harness.view.minimapMinEditorColumns = 44
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        let expected = GridAccessoryPolicy.targetGridSize(
            outerCols: harness.outerCols, outerRows: harness.outerRows,
            cellWidth: harness.view.cellSize.width, gutterWidth: 104)
        #expect(request?.cols == expected.cols)
        #expect(request?.rows == expected.rows)
    }

    @Test func gutterWaitsForResizeAcknowledgementAndNeverBecomesAGridCell() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()

        let request = requests.last!
        #expect(!request.releasesOwnership)
        guard let requesting = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        else {
            Issue.record("missing accessory state")
            return
        }
        #expect(requesting.ownership == .requesting(
            cols: request.cols, rows: request.rows))
        #expect(requesting.gutterFrame == nil)
        #expect(harness.view.accessoryInteractionView(at: NSPoint(
            x: CGFloat(request.cols) * harness.view.cellSize.width + 1,
            y: harness.view.cellSize.height)) == nil)

        harness.acknowledge(request)
        guard let owned = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let interaction = owned.interactionFrame
        else {
            Issue.record("acknowledged gutter missing")
            return
        }
        #expect(owned.ownership == .owned(cols: request.cols, rows: request.rows))
        #expect(owned.minimapLayerSuperviewIsGridLayer)
        let gutterPoint = NSPoint(x: interaction.minX + 1, y: interaction.midY)
        #expect(harness.view.accessoryInteractionView(at: gutterPoint) != nil)
        #expect(harness.view.cell(at: gutterPoint) == nil)
    }

    @Test func disablingMinimapReleasesOwnershipAndHidesImmediately() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        harness.acknowledge(requests.last!)

        harness.view.showsMinimap = false
        #expect(requests.last?.releasesOwnership == true)
        let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        #expect(snapshot?.ownership == .releasing)
        #expect(snapshot?.gutterFrame == nil)
        #expect(snapshot?.interactionFrame == nil)
    }

    @Test func removingTopologyReleasesAnOwnedGutterImmediately() {
        let harness = AccessoryHarness()
        var requests: [GridAccessorySizeRequest] = []
        harness.view.onGridAccessorySizeRequest = { requests.append($0) }
        harness.presentInitial()
        harness.acknowledge(requests.last!)

        harness.view.removeMinimapTopology(windowHandle: harness.windowHandle)
        #expect(requests.last?.releasesOwnership == true)
        let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)
        #expect(snapshot?.ownership == .releasing)
        #expect(snapshot?.gutterFrame == nil)
        #expect(snapshot?.interactionFrame == nil)
    }

    @Test func nativeScrollerDefaultsOffAndUsesTrailingTwelvePoints() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        #expect(harness.view.showsNativeScrollbars == false)
        #expect(harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.scrollerIsVisible == false)

        harness.view.showsNativeScrollbars = true
        guard let snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let interaction = snapshot.interactionFrame,
            let scroller = harness.view.editorAccessoryScroller(gridID: 2)
        else {
            Issue.record("native scroller missing")
            return
        }
        #expect(snapshot.scrollerIsVisible)
        #expect(abs(scroller.frame.width - 12) < 0.001)
        #expect(abs(scroller.frame.maxX - interaction.width) < 0.001)
    }

    @Test func contentChunksAccumulateUntilVisibleCoverageOrCompletion() {
        let harness = AccessoryHarness()
        var sizeRequest: GridAccessorySizeRequest?
        var contentRequest: MinimapContentRangeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.view.onMinimapContentRangeRequest = { contentRequest = $0 }
        harness.view.setMinimapTopologies([MinimapBufferTopology(
            windowHandle: harness.windowHandle, bufferHandle: 44,
            changedTick: 8, totalLineCount: 2_000,
            highlightGeneration: 3, tabstop: 4,
            bufferLabel: "sample.swift", filetype: "swift")])
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)

        guard let request = contentRequest,
            let display = harness.view.editorAccessoryDebugSnapshot(
                gridID: 2)?.displayRange
        else {
            Issue.record("minimap request missing")
            return
        }
        #expect(request.maxColumns == 160)
        let middle = display.lowerBound + display.count / 2
        let firstLines = (display.lowerBound..<middle).map {
            MinimapLine(text: "line \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: display.lowerBound,
            lastLine: middle, complete: false, lines: firstLines))
        var snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == nil)
        #expect(snapshot.pendingRange == request.lineRange)
        #expect(snapshot.accumulatedLineCount == firstLines.count)

        let secondLines = (middle..<display.upperBound).map {
            MinimapLine(text: "line \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: middle,
            lastLine: display.upperBound, complete: false, lines: secondLines))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == display)
        #expect(snapshot.pendingRange == request.lineRange,
                "coverage may publish, but only complete terminates the request")

        let tailStart = display.upperBound
        let tailEnd = min(request.lineRange.upperBound, tailStart + 16)
        let tailLines = (tailStart..<tailEnd).map {
            MinimapLine(text: "tail \($0)")
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: tailStart,
            lastLine: tailEnd, complete: false, lines: tailLines))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.acceptedRange == display,
                "tail chunks must not republish and restart CoreText work")
        #expect(snapshot.accumulatedLineCount
            == firstLines.count + secondLines.count + tailLines.count)

        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology, firstLine: request.lineRange.upperBound,
            lastLine: request.lineRange.upperBound, complete: true, lines: []))
        snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.pendingRange == nil)
        #expect(snapshot.acceptedRange == request.lineRange,
                "the final chunk publishes the complete prefetched window once")
    }

    @Test func minimapMarkersUseTheSameSnappedScrollResidual() {
        let harness = AccessoryHarness()
        var request: GridAccessorySizeRequest?
        harness.view.onGridAccessorySizeRequest = { request = $0 }
        harness.presentInitial()
        harness.acknowledge(request!)
        let before = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!

        harness.view.present(accessoryFlush(harness.store, [
            .gridScroll(
                grid: 2, top: 0, bottom: request!.rows,
                left: 0, right: request!.cols, rows: 1, cols: 0),
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: 101,
                botline: 101 + request!.rows, curline: 105, curcol: 2,
                lineCount: 2_000, scrollDelta: 1),
        ]))
        let retargeted = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(abs((before.viewportFrame?.minY ?? 0)
            - (retargeted.viewportFrame?.minY ?? 0)) <= 0.5,
            "authoritative row advance plus -1 residual must be visually continuous")

        _ = harness.view.advanceAnimations(
            by: 0.08, nominalDisplayPeriod: 1.0 / 60.0)
        let advanced = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(advanced.viewportFrame?.minY != retargeted.viewportFrame?.minY)
        #expect(advanced.cursorFrame?.minY != retargeted.cursorFrame?.minY)
    }

    @Test func railEdgeShiftUsesAContinuousExactContentResidual() {
        let harness = AccessoryHarness()
        harness.view.minimapPitch = 6
        var sizeRequest: GridAccessorySizeRequest?
        var contentRequest: MinimapContentRangeRequest?
        harness.view.onGridAccessorySizeRequest = { sizeRequest = $0 }
        harness.view.onMinimapContentRangeRequest = { contentRequest = $0 }
        harness.presentInitial()
        harness.acknowledge(sizeRequest!)

        guard let request = contentRequest else {
            Issue.record("content request missing")
            return
        }
        harness.view.provideMinimapContent(MinimapContentChunk(
            requestID: request.requestID, gridID: 2,
            topology: request.topology,
            firstLine: request.lineRange.lowerBound,
            lastLine: request.lineRange.upperBound, complete: true,
            lines: request.lineRange.map { MinimapLine(text: "line \($0)") }))

        guard let initialDisplay = harness.view.editorAccessoryDebugSnapshot(
            gridID: 2)?.displayRange
        else {
            Issue.record("display range missing")
            return
        }
        let rows = sizeRequest!.rows
        let edgeTop = initialDisplay.upperBound - rows
        harness.view.present(accessoryFlush(harness.store, [
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: edgeTop,
                botline: initialDisplay.upperBound, curline: edgeTop + 4,
                curcol: 2, lineCount: 2_000, scrollDelta: 0),
        ]))
        guard let before = harness.view.editorAccessoryDebugSnapshot(gridID: 2),
            let beforeContentY = before.contentFrame?.minY,
            let beforeViewportY = before.viewportFrame?.minY
        else {
            Issue.record("settled minimap geometry missing")
            return
        }

        harness.view.present(accessoryFlush(harness.store, [
            .gridScroll(
                grid: 2, top: 0, bottom: rows, left: 0,
                right: sizeRequest!.cols, rows: 1, cols: 0),
            .winViewport(
                grid: 2, win: harness.windowHandle, topline: edgeTop + 1,
                botline: initialDisplay.upperBound + 1,
                curline: edgeTop + 5, curcol: 2,
                lineCount: 2_000, scrollDelta: 1),
        ]))
        var snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
        #expect(snapshot.displayRange?.lowerBound
            == initialDisplay.lowerBound + 1)
        #expect(abs(snapshot.displayRangeResidual + 1) < 0.001)
        #expect(abs((snapshot.contentFrame?.minY ?? .infinity)
            - beforeContentY) <= 0.001,
            "the logical range rotation must not move pixels at insertion")
        #expect(abs((snapshot.viewportFrame?.minY ?? .infinity)
            - beforeViewportY) <= 0.5)

        var previousContentY = beforeContentY
        for _ in 0..<60 where !harness.view.animationsAreIdle {
            _ = harness.view.advanceAnimations(
                by: 1.0 / 120.0,
                nominalDisplayPeriod: 1.0 / 120.0)
            snapshot = harness.view.editorAccessoryDebugSnapshot(gridID: 2)!
            let contentY = snapshot.contentFrame!.minY
            #expect(contentY <= previousContentY + 0.001,
                    "edge content must settle monotonically without sawteeth")
            #expect(abs(snapshot.viewportFrame!.minY - beforeViewportY) <= 0.5,
                    "the viewport marker stays pinned while its rail tracks")
            previousContentY = contentY
        }

        let pitch = GridAccessoryPolicy.linePitch(
            scale: 2, minimapScale: harness.view.minimapScale,
            minimapPitch: harness.view.minimapPitch)
        #expect(harness.view.animationsAreIdle)
        #expect(abs(previousContentY - (beforeContentY - pitch)) <= 0.001)
        #expect(abs(snapshot.displayRangeResidual) <= 0.001)
    }
}

@Suite struct MinimapRasterizerTests {
    @Test func coreTextMiniaturePreservesSyntaxForegrounds() {
        let text = "let answer = 42"
        let image = MinimapRasterizer.render(
            lines: [MinimapLine(text: text, spans: [
                MinimapHighlightSpan(byteRange: 0..<3, foregroundRGB: 0xFF3030),
                MinimapHighlightSpan(byteRange: 13..<15, foregroundRGB: 0x30FF30),
            ])], width: 88, scale: 2,
            backgroundRGB: 0x000000, defaultForegroundRGB: 0xE0E0E0)!
        let bytes = image.dataProvider!.data! as Data
        var sawRed = false
        var sawGreen = false
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let blue = bytes[index]
            let green = bytes[index + 1]
            let red = bytes[index + 2]
            sawRed = sawRed || (red > 80 && red > green * 2 && red > blue * 2)
            sawGreen = sawGreen || (green > 80 && green > red * 2 && green > blue * 2)
        }
        #expect(sawRed)
        #expect(sawGreen)
    }

    @Test func topologyTabstopControlsMiniatureIndentation() {
        func firstInkX(_ text: String) -> Int? {
            let image = MinimapRasterizer.render(
                lines: [MinimapLine(text: text)], width: 88, scale: 2,
                backgroundRGB: 0x000000, defaultForegroundRGB: 0xFFFFFF,
                minimapScale: 0.20, minimapPitch: 3, tabstop: 4,
                editorFontSize: 13)!
            let bytes = image.dataProvider!.data! as Data
            for x in 0..<image.width {
                for y in 0..<image.height {
                    let index = y * image.bytesPerRow + x * 4
                    if bytes[index] > 20 || bytes[index + 1] > 20
                        || bytes[index + 2] > 20
                    { return x }
                }
            }
            return nil
        }
        let plain = firstInkX("x")!
        let indented = firstInkX("\tx")!
        #expect(indented > plain + 4)
    }
}
