// Real-nvim regression guard for wrapped-line scrolling. With 'wrap', every
// wheel step repaints the partially visible wrapped line at the window's
// bottom boundary in addition to the newly exposed strip; the classifier
// must treat those edge-hugging repaints as scroll by-products (display-
// linked) rather than settling the motion on every step — the field-
// reported wrap stutter. On failure each offending flush is printed with
// its raw wire shape.

import Foundation
import GridKit
import NvimKit
import Testing

private let probeNvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var probeNvimAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: probeNvimPath)
}

@MainActor
private final class WireCollector {
    struct FlushRecord {
        var scrolls: [String] = []
        var viewports: [String] = []
        var cursorGotos: [String] = []
        var lineRows: Set<Int> = []
        var otherEvents: Set<String> = []
        var disposition = ""
        var interpolates: Bool?

        var carriesScroll: Bool { !scrolls.isEmpty }

        var summary: String {
            var lines = ["  disposition=\(disposition) "
                + "interpolates=\(interpolates.map(String.init) ?? "nil")"]
            lines += scrolls.map { "  grid_scroll \($0)" }
            lines += viewports.map { "  win_viewport \($0)" }
            lines += cursorGotos.map { "  cursor_goto \($0)" }
            if !lineRows.isEmpty { lines.append("  grid_line rows=\(lineRows.sorted())") }
            if !otherEvents.isEmpty { lines.append("  other=\(otherEvents.sorted())") }
            return lines.joined(separator: "\n")
        }
    }

    let store = GridStore()
    private(set) var records: [FlushRecord] = []
    private var current = FlushRecord()

    func consume(_ batch: RedrawBatch) {
        for event in batch.events {
            switch event {
            case .gridScroll(let grid, let top, let bottom, let left, let right, let rows, let cols):
                current.scrolls.append(
                    "g\(grid) r\(top)..<\(bottom) c\(left)..<\(right) rows=\(rows) cols=\(cols)")
            case .winViewport(let grid, _, let topline, let botline, let curline, _, _, let delta):
                current.viewports.append(
                    "g\(grid) top=\(topline) bot=\(botline) curline=\(curline) delta=\(delta)")
            case .gridCursorGoto(let grid, let row, let col):
                current.cursorGotos.append("g\(grid) row=\(row) col=\(col)")
            case .gridLine(let grid, let row, _, _, _):
                if grid == 1 {
                    current.otherEvents.insert("gridLine(g1 r\(row))")
                } else {
                    current.lineRows.insert(row)
                }
            case .flush:
                break
            default:
                current.otherEvents.insert(
                    String(String(describing: event).prefix(while: { $0 != "(" })))
            }
        }
        let disposition = store.applyDeferred(batch)
        guard batch.events.contains(where: {
            if case .flush = $0 { return true }
            return false
        }) else { return }
        switch disposition {
        case .none:
            return
        case .immediate:
            current.disposition = "IMMEDIATE"
        case .displayLinked:
            current.disposition = "displayLinked"
        }
        if let flush = store.consumePendingPresentation() {
            current.interpolates = flush.allowsScrollInterpolation
        }
        records.append(current)
        current = FlushRecord()
    }
}

@Suite("Wrapped scrolling stays display-linked", .serialized)
struct WrapScrollProbeTests {
    @Test(
        "wheel steps over wrapped lines classify display-linked in both directions",
        .enabled(if: probeNvimAvailable, "nvim not found at \(probeNvimPath)"),
        .timeLimit(.minutes(2)))
    @MainActor
    func wrappedWheelScrollingInterpolates() async throws {
        let session = NvimSession(configuration: NvimLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: probeNvimPath),
            arguments: ["--embed", "--clean", "-i", "NONE"]))
        try await session.start()
        _ = try await session.handshake()

        let collector = WireCollector()
        let consumer = Task { @MainActor in
            for await batch in session.uiEvents {
                if Task.isCancelled { return }
                collector.consume(batch)
            }
        }
        defer { consumer.cancel() }

        // Match the app's attach exactly (NvimController.launchSession):
        // without ext_messages the ruler repaints grid 1 on every scroll and
        // the classifier correctly refuses to interpolate across it.
        try await session.attachUI(
            width: 40, height: 12,
            options: [
                "rgb": .bool(true),
                "ext_linegrid": .bool(true),
                "ext_multigrid": .bool(true),
                "ext_cmdline": .bool(true),
                "ext_popupmenu": .bool(true),
                "ext_messages": .bool(true),
            ])

        _ = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    """
                    -- Managed-baseline parity: the app releases the in-grid
                    -- statusline to the native bar. Without this, the
                    -- default laststatus=2 statusline repaints grid 1 on
                    -- every scroll and correctly blocks interpolation.
                    vim.o.laststatus = 0
                    vim.o.wrap = true
                    vim.o.number = true
                    vim.o.mousescroll = "ver:1,hor:1"
                    vim.o.mouse = "a"
                    local lines = {}
                    for i = 1, 40 do
                      if i % 3 == 0 then
                        lines[i] = ("L%02d "):format(i) .. ("wrap-content-%02d "):format(i):rep(9)
                      else
                        lines[i] = ("L%02d short"):format(i)
                      end
                    end
                    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
                    vim.api.nvim_win_set_cursor(0, {1, 0})
                    return true
                    """),
                .array([]),
            ],
            timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(400))
        let startupFlushes = collector.records.count

        for direction in ["down", "down", "down", "down", "down", "down",
                          "down", "down", "down", "down",
                          "up", "up", "up", "up", "up"]
        {
            await session.notify(
                "nvim_input_mouse",
                [
                    .string("wheel"), .string(direction), .string(""),
                    .int(2), .int(6), .int(10),
                ])
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(200))

        let scrollRecords = collector.records.dropFirst(startupFlushes)
            .filter(\.carriesScroll)
        #expect(scrollRecords.count >= 10,
                "wheel steps must produce scroll-carrying flushes")
        for (index, record) in scrollRecords.enumerated() {
            let interpolated = record.disposition == "displayLinked"
                && record.interpolates == true
            #expect(interpolated, "scroll flush \(index) settled the motion")
            if !interpolated {
                print("--- offending flush \(index)\n\(record.summary)")
            }
        }

        await session.notify("nvim_command", [.string("qa!")])
        _ = await session.shutdown(termGrace: .seconds(1), killGrace: .seconds(1))
    }
}
