import AppKit
import NvimKit
import SurfaceKit
import Testing

@testable import SuperlemonApp

private struct SentNotification: Equatable {
    var method: String
    var params: [Value]
}

@MainActor
private final class NotificationRecorder {
    var values: [SentNotification] = []

    func append(method: String, params: [Value]) {
        values.append(SentNotification(method: method, params: params))
    }
}

@MainActor
private struct BridgeHarness {
    let surface: GridSurfaceView
    let bridge: MinimapBridge
    let notifications: NotificationRecorder

    init() {
        let surface = GridSurfaceView(frame: .zero, font: FontSpec(name: "Menlo"))
        let notifications = NotificationRecorder()
        self.surface = surface
        self.notifications = notifications
        bridge = MinimapBridge(surface: surface) { [weak notifications] method, params in
            notifications?.append(method: method, params: params)
        }
    }

    func request(
        id: UInt64, grid: Int = 2,
        topology: MinimapBufferTopology,
        range: Range<Int>, maxColumns: Int = 160
    ) {
        surface.onMinimapContentRangeRequest?(MinimapContentRangeRequest(
            requestID: id,
            gridID: grid,
            topology: topology,
            lineRange: range,
            maxColumns: maxColumns))
    }
}

private func object(_ fields: (String, Value)...) -> Value {
    .map(fields.map { (.string($0.0), $0.1) })
}

private func windowsPayload(_ entries: [Value]) -> Value {
    object(("kind", .string("windows")), ("windows", .array(entries)))
}

private func windowEntry(
    window: Int = 20,
    buffer: Int = 44,
    changedTick: Int64 = 7,
    lineCount: Int = 1_000,
    highlightGeneration: UInt64 = 3,
    tabstop: Int = 4,
    bufferName: String = "/tmp/example.swift",
    filetype: String = "swift"
) -> Value {
    object(
        ("winid", .int(Int64(window))),
        ("bufnr", .int(Int64(buffer))),
        ("changedtick", .int(changedTick)),
        ("line_count", .int(Int64(lineCount))),
        ("highlight_generation", .uint(highlightGeneration)),
        ("tabstop", .int(Int64(tabstop))),
        ("buffer_name", .string(bufferName)),
        ("filetype", .string(filetype)))
}

private func invalidationPayload(
    buffer: Int = 44,
    changedTick: Int64,
    lineCount: Int,
    highlightGeneration: UInt64,
    firstLine: Int = 0,
    lastLine: Int = -1,
    newLastLine: Int = -1,
    detached: Bool = false,
    highlights: Bool = false
) -> Value {
    object(
        ("kind", .string("invalidate")),
        ("bufnr", .int(Int64(buffer))),
        ("changedtick", .int(changedTick)),
        ("line_count", .int(Int64(lineCount))),
        ("highlight_generation", .uint(highlightGeneration)),
        ("firstline", .int(Int64(firstLine))),
        ("lastline", .int(Int64(lastLine))),
        ("new_lastline", .int(Int64(newLastLine))),
        ("detached", .bool(detached)),
        ("highlights", .bool(highlights)))
}

private func linePayload(
    _ line: Int, text: String = "x", spans: [Value] = []
) -> Value {
    object(
        ("line", .int(Int64(line))),
        ("text", .string(text)),
        ("byte_length", .int(Int64(text.utf8.count))),
        ("truncated", .bool(false)),
        ("spans", .array(spans)))
}

private func runtimeLinePayload(
    _ line: Int,
    text: String,
    byteLength: Int,
    truncated: Bool,
    spans: [Value]
) -> Value {
    object(
        ("line", .int(Int64(line))),
        ("text", .string(text)),
        ("byte_length", .int(Int64(byteLength))),
        ("truncated", .bool(truncated)),
        ("spans", .array(spans)))
}

private func spanPayload(
    start: Int,
    end: Int,
    source: String = "normal",
    priority: Int = 0,
    order: Int = 0,
    style: Value
) -> Value {
    object(
        ("start_col", .int(Int64(start))),
        ("end_col", .int(Int64(end))),
        ("source", .string(source)),
        ("priority", .int(Int64(priority))),
        ("order", .int(Int64(order))),
        ("style", style))
}

private func contentPayload(
    requestID: UInt64,
    topology: MinimapBufferTopology,
    firstLine: Int,
    lastLine: Int,
    complete: Bool,
    lines: [Value],
    window: Int? = nil,
    buffer: Int? = nil,
    changedTick: Int64? = nil,
    lineCount: Int? = nil,
    highlightGeneration: UInt64? = nil
) -> Value {
    object(
        ("kind", .string("content")),
        ("request_id", .string(String(requestID))),
        ("winid", .int(Int64(window ?? topology.windowHandle))),
        ("bufnr", .int(Int64(buffer ?? topology.bufferHandle))),
        ("changedtick", .int(changedTick ?? topology.changedTick)),
        ("line_count", .int(Int64(lineCount ?? topology.totalLineCount))),
        ("highlight_generation", .uint(
            highlightGeneration ?? topology.highlightGeneration)),
        ("firstline", .int(Int64(firstLine))),
        ("lastline", .int(Int64(lastLine))),
        ("complete", .bool(complete)),
        ("lines", .array(lines)))
}

@MainActor
@Suite struct MinimapBridgeTests {
    @Test func windowsInvalidationAndEmptySnapshotMaintainTopology() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handleNotification(
            "not-superlemon", params: [windowsPayload([])]) == false)
        #expect(harness.bridge.handleNotification(
            "superlemon.minimap", params: []) == true)

        let initial = windowsPayload([
            windowEntry(),
            windowEntry(
                window: 21, buffer: 45, changedTick: 2, lineCount: 50,
                highlightGeneration: 4, tabstop: 8,
                bufferName: "/tmp/other.lua", filetype: "lua"),
        ])
        #expect(harness.bridge.handlePayload(initial))
        #expect(harness.bridge.topologiesByWindow.count == 2)
        let first = try #require(harness.bridge.topology(for: 20))
        #expect(first.bufferHandle == 44)
        #expect(first.changedTick == 7)
        #expect(first.bufferLabel == "/tmp/example.swift")
        #expect(first.filetype == "swift")

        #expect(harness.bridge.handlePayload(invalidationPayload(
            changedTick: 8,
            lineCount: 1_001,
            highlightGeneration: 3,
            firstLine: 10,
            lastLine: 11,
            newLastLine: 12)))
        let changed = try #require(harness.bridge.topology(for: 20))
        #expect(changed.changedTick == 8)
        #expect(changed.totalLineCount == 1_001)
        #expect(harness.bridge.topology(for: 21)?.changedTick == 2)

        // Older invalidations cannot regress an already-installed topology.
        #expect(!harness.bridge.handlePayload(invalidationPayload(
            changedTick: 7,
            lineCount: 1_000,
            highlightGeneration: 3)))
        #expect(harness.bridge.topology(for: 20) == changed)

        #expect(harness.bridge.handlePayload(invalidationPayload(
            changedTick: 8,
            lineCount: 1_001,
            highlightGeneration: 5,
            highlights: true)))
        #expect(harness.bridge.topology(for: 20)?.highlightGeneration == 5)

        let latest = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 11, topology: latest, range: 0..<1)
        #expect(harness.bridge.handlePayload(windowsPayload([])))
        #expect(harness.bridge.topologiesByWindow.isEmpty)
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 11,
            topology: latest,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])))
    }

    @Test func surfaceRequestsEncodeOneBoundedProviderNotification() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(
            lineCount: 10_000)])))
        let topology = try #require(harness.bridge.topology(for: 20))

        harness.request(
            id: 42,
            topology: topology,
            range: 100..<1_000,
            maxColumns: 10_000)

        let sent = try #require(harness.notifications.values.last)
        #expect(sent.method == "nvim_exec_lua")
        #expect(sent.params.count == 2)
        #expect(sent.params[0] == .string(
            "return require('superlemon.minimap').request(...)"))
        let arguments = try #require(sent.params[1].arrayValue)
        #expect(arguments.count == 1)
        let options = try #require(arguments.first)
        #expect(options["request_id"] == .string("42"))
        #expect(options["winid"] == .int(20))
        #expect(options["bufnr"] == .int(44))
        #expect(options["changedtick"] == .int(7))
        #expect(options["line_count"] == .int(10_000))
        #expect(options["highlight_generation"] == .uint(3))
        #expect(options["firstline"] == .int(100))
        #expect(options["lastline"] == .int(484))
        #expect(options["max_columns"] == .int(256))

        // A stale topology and a negative range are rejected before the wire.
        let stale = MinimapBufferTopology(
            windowHandle: 20,
            bufferHandle: 44,
            changedTick: 6,
            totalLineCount: 10_000,
            highlightGeneration: 3)
        harness.request(id: 43, topology: stale, range: 0..<10)
        harness.request(id: 44, topology: topology, range: -1..<10)
        #expect(harness.notifications.values.count == 1)
    }

    @Test func contentRequiresExactMonotonicChunkSequence() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(lineCount: 100)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 51, topology: topology, range: 10..<14)

        let first = contentPayload(
            requestID: 51,
            topology: topology,
            firstLine: 10,
            lastLine: 12,
            complete: false,
            lines: [linePayload(10), linePayload(11)])
        #expect(harness.bridge.handlePayload(first))
        #expect(!harness.bridge.handlePayload(first), "duplicate chunk must be stale")

        let gap = contentPayload(
            requestID: 51,
            topology: topology,
            firstLine: 13,
            lastLine: 14,
            complete: true,
            lines: [linePayload(13)])
        #expect(!harness.bridge.handlePayload(gap))

        let prematureNonfinal = contentPayload(
            requestID: 51,
            topology: topology,
            firstLine: 12,
            lastLine: 14,
            complete: false,
            lines: [linePayload(12), linePayload(13)])
        #expect(!harness.bridge.handlePayload(prematureNonfinal))

        let final = contentPayload(
            requestID: 51,
            topology: topology,
            firstLine: 12,
            lastLine: 14,
            complete: true,
            lines: [linePayload(12), linePayload(13)])
        #expect(harness.bridge.handlePayload(final))
        #expect(!harness.bridge.handlePayload(final), "completed identity must be retired")
    }

    @Test func contentRejectsWrongIdentityAndNonMonotonicGenerations() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(lineCount: 100)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 61, topology: topology, range: 0..<1)
        let lines = [linePayload(0)]

        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines,
            window: 21)))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines,
            buffer: 45)))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines,
            changedTick: 6)))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines,
            lineCount: 101)))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines,
            highlightGeneration: 2)))

        // Rejections never consume the valid pending request.
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 61, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines)))

        let olderWindows = windowsPayload([windowEntry(
            changedTick: 7,
            lineCount: 100,
            highlightGeneration: 2)])
        #expect(!harness.bridge.handlePayload(olderWindows))
        #expect(harness.bridge.topology(for: 20) == topology)

        harness.request(id: 62, topology: topology, range: 0..<1)
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(
            buffer: 46,
            changedTick: 1,
            lineCount: 10,
            highlightGeneration: 5)])))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 62, topology: topology,
            firstLine: 0, lastLine: 1, complete: true, lines: lines)))
    }

    @Test func newerContentHeaderAdvancesTopologyAndForcesFreshIdentity() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(
            lineCount: 100)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 63, topology: topology, range: 0..<1)

        // This is the exact real-load race: Lua received the request after the
        // displayed buffer advanced beyond the topology SurfaceKit used. The
        // body must not install under the old identity, but its monotonic header
        // is sufficient to refresh topology and retire request 63.
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 63,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0, text: "new")],
            changedTick: 8,
            lineCount: 101,
            highlightGeneration: 4)))

        let advanced = try #require(harness.bridge.topology(for: 20))
        #expect(advanced.changedTick == 8)
        #expect(advanced.totalLineCount == 101)
        #expect(advanced.highlightGeneration == 4)
        #expect(advanced.tabstop == topology.tabstop)
        #expect(advanced.bufferLabel == topology.bufferLabel)
        #expect(advanced.filetype == topology.filetype)

        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 63,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])), "old request must be retired")

        harness.request(id: 64, topology: advanced, range: 0..<1)
        let options = try #require(
            harness.notifications.values.last?.params[1].arrayValue?.first)
        #expect(options["changedtick"] == .int(8))
        #expect(options["line_count"] == .int(101))
        #expect(options["highlight_generation"] == .uint(4))
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 64,
            topology: advanced,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])))
    }

    @Test func contentDecodesRGBTraitsAndReverseBackgroundSafely() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(lineCount: 20)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 71, topology: topology, range: 0..<2)

        let normal = spanPayload(
            start: 0,
            end: 5,
            style: object(("fg", .uint(0x112233))))
        let styled = spanPayload(
            start: 0,
            end: 5,
            source: "treesitter",
            priority: 100,
            order: 1,
            style: object(
                ("fg", .uint(0x445566)),
                ("bold", .bool(true)),
                ("italic", .bool(true)),
                ("underline", .bool(true))))
        let reversed = spanPayload(
            start: 0,
            end: 2,
            source: "extmark",
            priority: 220,
            order: 2,
            style: object(
                ("bg", .uint(0x102030)),
                ("reverse", .bool(true)),
                ("undercurl", .bool(true))))

        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 71,
            topology: topology,
            firstLine: 0,
            lastLine: 2,
            complete: true,
            lines: [
                linePayload(0, text: "local", spans: [normal, styled]),
                linePayload(1, text: "xy", spans: [reversed]),
            ])))

        harness.request(id: 72, topology: topology, range: 0..<1)
        let invalidColor = spanPayload(
            start: 0,
            end: 1,
            style: object(("fg", .uint(0x1_000000))))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 72,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0, spans: [invalidColor])])))

        let invalidTrait = spanPayload(
            start: 0,
            end: 1,
            style: object(
                ("fg", .uint(0x123456)),
                ("bold", .string("yes"))))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 72,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0, spans: [invalidTrait])])))

        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 72,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])))
    }

    @Test func emptyLuaStyleArrayIsTheOnlyAcceptedArrayShapedStyle() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(lineCount: 2)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 72_001, topology: topology, range: 0..<1)

        // A real legacy-syntax chunk can contain a resolved Normal span and a
        // later semantic no-op style encoded as [] by Lua's ambiguous empty
        // table. It must inherit without invalidating the entire 16-line chunk.
        let normal = spanPayload(
            start: 0,
            end: 6,
            style: object(("fg", .uint(0xD0D0D0))))
        let emptyLegacy = spanPayload(
            start: 5,
            end: 6,
            source: "legacy",
            priority: 50,
            order: 12,
            style: .array([]))
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 72_001,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(
                0, text: "value!", spans: [normal, emptyLegacy])])))

        // The compatibility boundary is deliberately exact: a nonempty
        // array is not a Lua empty dictionary and remains malformed.
        harness.request(id: 72_002, topology: topology, range: 0..<1)
        let malformed = spanPayload(
            start: 0,
            end: 1,
            source: "legacy",
            priority: 50,
            order: 13,
            style: .array([.bool(true)]))
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 72_002,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0, spans: [malformed])])))

        // A malformed style does not consume the pending identity.
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 72_002,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])))
    }

    @Test func exactRuntimeFixtureAcceptsTwentyFourSixteenLineChunks() throws {
        let harness = BridgeHarness()
        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(
            lineCount: 384)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(
            id: 73,
            topology: topology,
            range: 0..<384,
            maxColumns: 256)

        let normalStyle = object(
            ("fg", .int(14_738_154)),
            ("bg", .int(1_316_379)))
        let fullStyle = object(
            ("fg", .int(1_122_867)),
            ("bg", .int(4_478_310)),
            ("sp", .int(7_833_753)),
            ("blend", .int(10)),
            ("bold", .bool(true)),
            ("italic", .bool(true)),
            ("underline", .bool(true)),
            ("undercurl", .bool(true)),
            ("underdouble", .bool(true)),
            ("underdotted", .bool(true)),
            ("underdashed", .bool(true)),
            ("strikethrough", .bool(true)),
            ("reverse", .bool(true)),
            ("standout", .bool(true)),
            ("nocombine", .bool(true)))

        for chunkIndex in 0..<24 {
            let firstLine = chunkIndex * 16
            let lastLine = firstLine + 16
            var lines: [Value] = []
            lines.reserveCapacity(16)
            for lineNumber in firstLine..<lastLine {
                let text: String
                let byteLength: Int
                let truncated: Bool
                if lineNumber == 0 {
                    text = "local emoji = '😀' -- fixture"
                    byteLength = text.utf8.count
                    truncated = false
                } else if lineNumber == 17 {
                    text = String(repeating: "😀", count: 256)
                    byteLength = text.utf8.count + 400
                    truncated = true
                } else {
                    text = String(format: "local value_%03d = %d", lineNumber + 1, lineNumber + 1)
                    byteLength = text.utf8.count
                    truncated = false
                }

                var spans = [spanPayload(
                    start: 0,
                    end: text.utf8.count,
                    style: normalStyle)]
                if lineNumber == 0 {
                    spans.append(spanPayload(
                        start: 0,
                        end: 5,
                        source: "extmark",
                        priority: 220,
                        order: 1_000_002,
                        style: fullStyle))
                }
                if lineNumber == 357 {
                    spans.append(spanPayload(
                        start: max(0, text.utf8.count - 1),
                        end: text.utf8.count,
                        source: "legacy",
                        priority: 50,
                        order: 357,
                        style: .array([])))
                }
                lines.append(runtimeLinePayload(
                    lineNumber,
                    text: text,
                    byteLength: byteLength,
                    truncated: truncated,
                    spans: spans))
            }

            let payload = object(
                ("kind", .string("content")),
                ("request_id", .string("73")),
                ("winid", .int(20)),
                ("bufnr", .int(44)),
                ("changedtick", .int(7)),
                ("line_count", .int(384)),
                ("highlight_generation", .int(3)),
                ("firstline", .int(Int64(firstLine))),
                ("lastline", .int(Int64(lastLine))),
                ("complete", .bool(chunkIndex == 23)),
                ("clamped", .bool(false)),
                ("highlight_source", .string("treesitter")),
                ("degraded", .string("legacy-budget")),
                ("lines", .array(lines)))
            #expect(harness.bridge.handlePayload(payload),
                "runtime-shaped chunk \(chunkIndex) should decode")
        }

        // The provider's final `complete` chunk retires the request identity.
        let replay = object(
            ("kind", .string("content")),
            ("request_id", .string("73")),
            ("winid", .int(20)),
            ("bufnr", .int(44)),
            ("changedtick", .int(7)),
            ("line_count", .int(384)),
            ("highlight_generation", .int(3)),
            ("firstline", .int(368)),
            ("lastline", .int(384)),
            ("complete", .bool(true)),
            ("lines", .array([])))
        #expect(!harness.bridge.handlePayload(replay))
    }

    @Test func malformedPayloadsAreRejectedWithoutDamagingPendingState() throws {
        let harness = BridgeHarness()
        #expect(!harness.bridge.handlePayload(.string("not-a-map")))
        #expect(!harness.bridge.handlePayload(object(("kind", .string("unknown")))))
        #expect(!harness.bridge.handlePayload(.map([
            (.string("kind"), .string("windows")),
            (.string("kind"), .string("windows")),
            (.string("windows"), .array([])),
        ])))
        #expect(!harness.bridge.handlePayload(windowsPayload([object(
            ("winid", .float(20)),
            ("bufnr", .int(44)),
            ("changedtick", .int(1)),
            ("line_count", .int(1)),
            ("highlight_generation", .int(1)),
            ("tabstop", .int(4)),
            ("filetype", .string("swift")))])))
        #expect(!harness.bridge.handlePayload(windowsPayload([object(
            ("winid", .uint(UInt64.max)),
            ("bufnr", .int(44)),
            ("changedtick", .int(1)),
            ("line_count", .int(1)),
            ("highlight_generation", .int(1)),
            ("tabstop", .int(4)),
            ("filetype", .string("swift")))])))

        #expect(harness.bridge.handlePayload(windowsPayload([windowEntry(lineCount: 10)])))
        let topology = try #require(harness.bridge.topology(for: 20))
        harness.request(id: 81, topology: topology, range: 0..<1)

        // Range says one line, but the array is empty. The valid response can
        // still follow because malformed content never advances the identity.
        #expect(!harness.bridge.handlePayload(contentPayload(
            requestID: 81,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [])))
        #expect(harness.bridge.handlePayload(contentPayload(
            requestID: 81,
            topology: topology,
            firstLine: 0,
            lastLine: 1,
            complete: true,
            lines: [linePayload(0)])))
    }
}
