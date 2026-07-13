import Foundation
import Testing

@testable import NvimKit

// MARK: - Helpers

private struct TimeoutError: Error {}

private func waitUntil(
    timeout: Duration = .seconds(20),
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw TimeoutError()
}

private actor EventSink {
    private(set) var events: [UIEvent] = []
    func add(_ batch: RedrawBatch) { events.append(contentsOf: batch.events) }

    func contains(_ predicate: @Sendable (UIEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}

private actor ExitBox {
    private(set) var event: NvimSession.LifecycleEvent?
    func set(_ e: NvimSession.LifecycleEvent) { event = e }
}

private actor TerminationBox {
    private(set) var outcome: NvimTermination?
    func set(_ value: NvimTermination) { outcome = value }
}

private actor NotificationSink {
    private(set) var notifications: [NvimSession.Notification] = []
    func add(_ notification: NvimSession.Notification) { notifications.append(notification) }
}

/// Full text of a gridLine event with repeats expanded.
private func lineText(_ event: UIEvent) -> String? {
    guard case .gridLine(_, _, _, let cells, _) = event else { return nil }
    return cells.map { String(repeating: $0.text, count: max(1, $0.repeatCount)) }.joined()
}

// MARK: - Session behavior without nvim

@Suite struct NvimSessionUnitTests {
    @Test func requestBeforeStartThrows() async {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(binaryURL: URL(fileURLWithPath: "/bin/cat")))
        await #expect(throws: NvimError.sessionNotRunning) {
            _ = try await session.request("nvim_get_api_info", [])
        }
    }

    @Test func processExitFailsInFlightRequests() async throws {
        // The child drains stdin without answering, so the request stays in
        // flight until controlled shutdown and must then fail.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec /bin/cat >/dev/null"]))
        try await session.start()

        let pending = Task {
            try await session.request("nvim_get_api_info", [], timeout: .seconds(10))
        }
        try await waitUntil { await session.pendingRequestCount == 1 }
        _ = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))

        await #expect(throws: NvimError.self) { _ = try await pending.value }

        // ...and later requests fail fast with the termination error.
        try await waitUntil {
            do {
                _ = try await session.request("x", [])
                return false
            } catch {
                return true
            }
        }
    }

    @Test func requestTimeoutRemovesPendingEntry() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec /bin/cat >/dev/null"]))
        try await session.start()

        await #expect(throws: NvimError.requestTimedOut(method: "never")) {
            _ = try await session.request("never", [], timeout: .milliseconds(50))
        }
        #expect(await session.pendingRequestCount == 0)

        _ = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))
    }

    @Test func requestCancellationIsImmediateAndRemovesPendingEntry() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec /bin/cat >/dev/null"]))
        try await session.start()

        let request = Task {
            try await session.request("cancel-me", [], timeout: .seconds(10))
        }
        try await waitUntil { await session.pendingRequestCount == 1 }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(await session.pendingRequestCount == 0)

        _ = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))
    }

    @Test func lateResponseAfterTimeoutIsIgnoredAndNextRequestSucceeds() async throws {
        // cat reflects our request as an incoming RPC request and reflects the
        // handler response back as the correlated response. Delaying one
        // handler creates a deterministic late-response race without a fixture
        // executable.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        await session.setRequestHandler { method, _ in
            if method == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
            return .success(.string("reply-\(method)"))
        }
        try await session.start()

        await #expect(throws: NvimError.requestTimedOut(method: "slow")) {
            _ = try await session.request("slow", [], timeout: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.pendingRequestCount == 0)

        let reply = try await session.request("fast", [], timeout: .seconds(1))
        #expect(reply == .string("reply-fast"))
        _ = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))
    }

    @Test func stderrIsCapturedInTail() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo oops-from-stderr >&2"]))
        try await session.start()
        try await waitUntil { session.stderrTail.contains("oops-from-stderr") }
    }

    @Test func lifecycleReportsExitCode() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo bye >&2; exit 3"]))
        let box = ExitBox()
        let watcher = Task {
            for await event in session.lifecycleEvents {
                await box.set(event)
                break
            }
        }
        try await session.start()
        try await waitUntil { await box.event != nil }
        watcher.cancel()
        guard case .exited(let code, let tail)? = await box.event else {
            Issue.record("expected exit event")
            return
        }
        #expect(code == 3)
        #expect(tail.contains("bye"))
    }

    @Test func shutdownReturnsReapedSIGTERMOutcomeWithoutEscalation() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]))
        try await session.start()

        let outcome = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))
        #expect(outcome.cause == .requestedShutdown)
        #expect(outcome.exitCode != nil)
        #expect(!outcome.didForceKill)
    }

    @Test func shutdownEscalatesIgnoredSIGTERMAndEmitsExactlyOnce() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"]))
        let lifecycleCount = Task {
            var count = 0
            for await _ in session.lifecycleEvents { count += 1 }
            return count
        }
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }
        try await session.start()
        // Give /bin/sh time to install SIG_IGN and exec sleep.
        try await Task.sleep(for: .milliseconds(50))

        async let first = session.shutdown(
            termGrace: .milliseconds(50), killGrace: .seconds(1))
        async let second = session.shutdown(
            termGrace: .milliseconds(50), killGrace: .seconds(1))
        let outcomes = await [first, second]

        #expect(outcomes[0] == outcomes[1])
        #expect(outcomes[0].cause == .requestedShutdown)
        #expect(outcomes[0].didForceKill)
        #expect(await lifecycleCount.value == 1)
        let emitted = await terminationOutcomes.value
        #expect(emitted == [outcomes[0]])
    }

    @Test func malformedMsgpackFailsPendingAndStillEmitsOneExitAndOutcome() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.15; printf '\\301'; exec /bin/sleep 30"]))
        let lifecycleCount = Task {
            var count = 0
            for await _ in session.lifecycleEvents { count += 1 }
            return count
        }
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }
        try await session.start()

        let pending = Task {
            try await session.request("will-fail", [], timeout: .seconds(10))
        }
        try await waitUntil { await session.pendingRequestCount == 1 }
        await #expect(throws: NvimError.protocolError("invalidFormatByte(193)")) {
            _ = try await pending.value
        }

        let emitted = await terminationOutcomes.value
        #expect(emitted.count == 1)
        guard let outcome = emitted.first else { return }
        guard case .protocolError(let message) = outcome.cause else {
            Issue.record("expected protocol-error termination")
            return
        }
        #expect(message.contains("invalidFormatByte"))
        #expect(await lifecycleCount.value == 1)
        #expect(await session.pendingRequestCount == 0)

        await #expect(throws: NvimError.protocolError("invalidFormatByte(193)")) {
            _ = try await session.request("after-failure", [])
        }
    }

    @Test func structurallyInvalidRPCFrameUsesProtocolFailureFunnel() async throws {
        // [3] is valid MessagePack but not a valid msgpack-RPC message type.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "sleep 0.15; printf '\\221\\003'; exec /bin/sleep 30",
                ]))
        let lifecycleCount = Task {
            var count = 0
            for await _ in session.lifecycleEvents { count += 1 }
            return count
        }
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }
        try await session.start()

        let pending = Task {
            try await session.request("will-fail", [], timeout: .seconds(10))
        }
        try await waitUntil { await session.pendingRequestCount == 1 }
        await #expect(throws: NvimError.protocolError("unknownMessageType(3)")) {
            _ = try await pending.value
        }

        let emitted = await terminationOutcomes.value
        #expect(emitted.count == 1)
        guard case .protocolError(let detail)? = emitted.first?.cause else {
            Issue.record("expected protocol-error termination")
            return
        }
        #expect(detail.contains("unknownMessageType(3)"))
        #expect(await lifecycleCount.value == 1)
        #expect(await session.pendingRequestCount == 0)
    }

    @Test func liveChildStdoutEOFFailsPendingAndTerminatesExactlyOnce() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "sleep 0.15; exec 1>&-; exec /bin/cat >/dev/null",
                ]))
        let lifecycleCount = Task {
            var count = 0
            for await _ in session.lifecycleEvents { count += 1 }
            return count
        }
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }
        try await session.start()

        let pending = Task {
            try await session.request("will-lose-transport", [], timeout: .seconds(10))
        }
        try await waitUntil { await session.pendingRequestCount == 1 }
        let expected = NvimError.ioFailure(
            "stdout closed while nvim process was still running")
        await #expect(throws: expected) { _ = try await pending.value }

        let emitted = await terminationOutcomes.value
        #expect(emitted.count == 1)
        #expect(
            emitted.first?.cause
                == .ioFailure("stdout closed while nvim process was still running"))
        #expect(await lifecycleCount.value == 1)
        #expect(await session.pendingRequestCount == 0)
    }

    @Test func ordinaryExitEOFRemainsOneProcessExitOutcome() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"]))
        let lifecycleEvents = Task {
            var events: [NvimSession.LifecycleEvent] = []
            for await event in session.lifecycleEvents { events.append(event) }
            return events
        }
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }

        try await session.start()
        let outcomes = await terminationOutcomes.value
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.cause == .processExit)
        #expect(outcomes.first?.exitCode == 0)
        #expect(await lifecycleEvents.value.count == 1)
    }

    @Test func missingProcessExitCallbackCannotStrandShutdownWaiters() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"]))
        await session.suppressProcessExitHandling()
        let terminationOutcomes = Task {
            var outcomes: [NvimTermination] = []
            for await outcome in session.terminationEvents { outcomes.append(outcome) }
            return outcomes
        }
        try await session.start()
        try await Task.sleep(for: .milliseconds(50))

        let clock = ContinuousClock()
        let start = clock.now
        async let first = session.shutdown(
            termGrace: .milliseconds(50), killGrace: .milliseconds(80))
        async let second = session.shutdown(
            termGrace: .milliseconds(50), killGrace: .milliseconds(80))
        let outcomes = await [first, second]
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed < .seconds(2))
        #expect(outcomes[0] == outcomes[1])
        #expect(outcomes[0].cause == .requestedShutdown)
        #expect(outcomes[0].didForceKill)
        #expect(await terminationOutcomes.value == [outcomes[0]])
        #expect(await session.shutdown() == outcomes[0])
    }

    @Test func declaredOversizeBecomesProtocolTermination() async throws {
        let limits = MsgpackDecodingLimits(
            maximumMessageBytes: 32,
            maximumContainerElements: 100,
            maximumNestingDepth: 10)
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", "printf '\\333\\000\\000\\001\\000'; exec /bin/sleep 30",
                ]),
            decodingLimits: limits)
        let outcomeTask = Task<NvimTermination?, Never> {
            for await outcome in session.terminationEvents { return outcome }
            return nil
        }
        try await session.start()

        let outcome = try #require(await outcomeTask.value)
        guard case .protocolError(let message) = outcome.cause else {
            Issue.record("expected protocol-error termination")
            return
        }
        #expect(message.contains("messageTooLarge"))
    }

    @Test func closedChildInputDoesNotRaiseSIGPIPE() async throws {
        // Keep the child alive briefly after closing stdin. This makes the
        // session write while its pipe has no reader: write(2) must return
        // EPIPE rather than terminating the whole test process with SIGPIPE.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 0<&-; exec /bin/sleep 5"]))
        let exitBox = ExitBox()
        let terminationBox = TerminationBox()
        let watcher = Task {
            for await event in session.lifecycleEvents {
                await exitBox.set(event)
                break
            }
        }
        let terminationWatcher = Task {
            for await outcome in session.terminationEvents {
                await terminationBox.set(outcome)
                break
            }
        }
        defer {
            watcher.cancel()
            terminationWatcher.cancel()
        }

        try await session.start()
        try await Task.sleep(for: .milliseconds(50))
        await session.notify("write_to_closed_pipe", [])
        try await waitUntil { await exitBox.event != nil }

        guard case .exited(_, _)? = await exitBox.event else {
            Issue.record("expected lifecycle exit event")
            return
        }
        try await waitUntil { await terminationBox.outcome != nil }
        guard case .ioFailure? = await terminationBox.outcome?.cause else {
            Issue.record("expected stdin write failure outcome")
            return
        }
    }

    @Test func notificationStreamBackpressuresWithoutDroppingBurst() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        try await session.start()

        for index in 0..<100 {
            await session.notify("event-\(index)", [])
        }
        // Let the pipe reader reach the channel's capacity before attaching a
        // consumer. The remaining protocol bytes must wait upstream rather
        // than being dropped or growing an unbounded in-memory queue.
        try await Task.sleep(for: .milliseconds(100))

        var received: [String] = []
        for await notification in session.notifications {
            received.append(notification.method)
            if received.count == 100 { break }
        }

        #expect(received == (0..<100).map { "event-\($0)" })
        _ = await session.shutdown(
            termGrace: .milliseconds(100), killGrace: .seconds(1))
    }

    @Test func notificationBatchPreservesFrameOrder() async throws {
        // cat echoes our one contiguous write back to the session decoder. If
        // the concatenated MessagePack frames are malformed or reordered, the
        // notification stream will not reproduce this batch exactly.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        let sink = NotificationSink()
        let watcher = Task {
            for await notification in session.notifications {
                await sink.add(notification)
            }
        }
        defer {
            watcher.cancel()
            Task { await session.terminate() }
        }

        try await session.start()
        await session.notifyBatch([
            .init(method: "first", params: [.string("a")]),
            .init(method: "second", params: [.int(2)], repeatCount: 3),
            .init(method: "third", params: [.bool(true)]),
        ])

        try await waitUntil { await sink.notifications.count == 5 }
        let received = await sink.notifications
        #expect(received.map(\.method) == [
            "first", "second", "second", "second", "third",
        ])
        #expect(received.map(\.params) == [
            [.string("a")], [.int(2)], [.int(2)], [.int(2)], [.bool(true)],
        ])
    }

    @Test func inputCommandsKeepRepeatsSemanticAndFIFOOrdered() {
        let commands: [NvimInputCommand] = [
            .keys("i"),
            .mouse(
                button: "wheel", action: "down", modifier: "S",
                grid: 3, row: 7, col: 11, repeatCount: 3),
            .keys("<Esc>"),
        ]

        let notifications = commands.flatMap(\.notifications)
        #expect(notifications.map(\.method) == [
            "nvim_input", "nvim_input_mouse", "nvim_input",
        ])
        #expect(notifications.first?.params == [.string("i")])
        #expect(notifications.last?.params == [.string("<Esc>")])
        #expect(notifications[1].repeatCount == 3)

        let expectedMouseParams: [Value] = [
            .string("wheel"), .string("down"), .string("S"),
            .int(3), .int(7), .int(11),
        ]
        #expect(notifications[1].params == expectedMouseParams)

        let empty = NvimInputCommand.mouse(
            button: "wheel", action: "up", modifier: "",
            grid: 1, row: 0, col: 0, repeatCount: 0)
        #expect(empty.notifications.isEmpty)

        let first = NvimInputCommand.mouse(
            button: "wheel", action: "down", modifier: "",
            grid: 1, row: 2, col: 3, repeatCount: 4)
        let second = NvimInputCommand.mouse(
            button: "wheel", action: "down", modifier: "",
            grid: 1, row: 2, col: 3, repeatCount: 5)
        #expect(first.coalesced(with: second) == .mouse(
            button: "wheel", action: "down", modifier: "",
            grid: 1, row: 2, col: 3, repeatCount: 9))
        #expect(first.coalesced(with: .keys("x")) == nil)

        let resize = NvimInputCommand.resize(cols: 120, rows: 40)
        #expect(resize.notifications == [
            .init(method: "nvim_ui_try_resize", params: [.int(120), .int(40)])
        ])
        #expect(resize.coalesced(with: .resize(cols: 121, rows: 41))
            == .resize(cols: 121, rows: 41))
        #expect(NvimInputCommand.paste("hello").notifications.isEmpty)
    }

    @Test func gridResizeCommandsEncodeExactlyAndCoalesceOnlyPerGrid() {
        let resize = NvimInputCommand.resizeGrid(grid: 7, cols: 132, rows: 48)
        #expect(resize.notifications == [
            .init(
                method: "nvim_ui_try_resize_grid",
                params: [.int(7), .int(132), .int(48)])
        ])

        // Zero dimensions are meaningful to Neovim (they delegate layout),
        // so this primitive must not rewrite them.
        #expect(NvimInputCommand.resizeGrid(grid: 9, cols: 0, rows: 0).notifications == [
            .init(
                method: "nvim_ui_try_resize_grid",
                params: [.int(9), .int(0), .int(0)])
        ])

        #expect(resize.coalesced(with: .resizeGrid(grid: 7, cols: 140, rows: 50))
            == .resizeGrid(grid: 7, cols: 140, rows: 50))
        #expect(resize.coalesced(with: .resizeGrid(grid: 8, cols: 140, rows: 50)) == nil)
        #expect(resize.coalesced(with: .resize(cols: 140, rows: 50)) == nil)
        #expect(NvimInputCommand.resize(cols: 132, rows: 48).coalesced(with: resize) == nil)
    }

    @Test func viewportTargetsEncodeValidatedZeroBasedViewportOperations() {
        let lua = """
            local window, expected_buffer, topline, activate = ...
            if not vim.api.nvim_win_is_valid(window) then
              return false
            end
            if vim.api.nvim_win_get_buf(window) ~= expected_buffer then
              return false
            end
            if activate then
              vim.api.nvim_set_current_win(window)
            end
            return vim.api.nvim_win_call(window, function()
              if vim.api.nvim_get_current_buf() ~= expected_buffer then
                return false
              end
              local cursor = vim.api.nvim_win_get_cursor(window)
              local line_count = vim.api.nvim_buf_line_count(expected_buffer)
              local anchor = math.max(1, math.min(topline + 1, line_count))
              local function set_cursor(line)
                local text = vim.api.nvim_buf_get_lines(
                  expected_buffer, line - 1, line, false)[1] or ""
                vim.api.nvim_win_set_cursor(
                  window, { line, math.min(cursor[2], #text) })
              end

              -- Anchor the cursor before restoring the view. Calling
              -- winrestview() with an off-screen cursor is immediately clamped by
              -- Neovim, before `w0`/`w$` can describe the requested viewport.
              set_cursor(anchor)
              local view = { topline = topline + 1 }
              vim.fn.winrestview(view)
              local first_visible = vim.fn.line("w0")
              local last_visible = vim.fn.line("w$")
              local target = math.max(first_visible, math.min(cursor[1], last_visible))
              set_cursor(target)
              vim.fn.winrestview(view)
              return true
            end)
            """

        let passive = NvimInputCommand.viewportTarget(
            grid: 3, window: 42, buffer: 99, topline: 120)
        #expect(passive.notifications == [
            .init(
                method: "nvim_exec_lua",
                params: [
                    .string(lua),
                    .array([.int(42), .int(99), .int(120), .bool(false)]),
                ])
        ])

        let activatingClamped = NvimInputCommand.viewportTarget(
            grid: 4, window: 43, buffer: 100, topline: -12, activate: true)
        #expect(activatingClamped.notifications == [
            .init(
                method: "nvim_exec_lua",
                params: [
                    .string(lua),
                    .array([.int(43), .int(100), .int(0), .bool(true)]),
                ])
        ])
    }

    @Test func viewportAndGridCoalescingPreservesFIFOBarriers() {
        let passiveA = NvimInputCommand.viewportTarget(
            grid: 3, window: 30, buffer: 300, topline: 10)
        let passiveANewer = NvimInputCommand.viewportTarget(
            grid: 4, window: 30, buffer: 301, topline: 20)
        let passiveB = NvimInputCommand.viewportTarget(
            grid: 5, window: 31, buffer: 302, topline: 30)
        let activeA = NvimInputCommand.viewportTarget(
            grid: 4, window: 30, buffer: 301, topline: 20, activate: true)

        // Window identity, rather than grid or buffer identity, owns a
        // viewport target. The newest adjacent target fully replaces the old
        // one, while activation semantics remain a hard ordering boundary.
        #expect(passiveA.coalesced(with: passiveANewer) == passiveANewer)
        #expect(passiveA.coalesced(with: passiveB) == nil)
        #expect(passiveA.coalesced(with: activeA) == nil)
        #expect(activeA.coalesced(with: passiveANewer) == nil)

        let commands: [NvimInputCommand] = [
            .resizeGrid(grid: 1, cols: 80, rows: 24),
            .resizeGrid(grid: 1, cols: 90, rows: 30),
            .keys("j"),
            .resizeGrid(grid: 1, cols: 100, rows: 32),
            .resizeGrid(grid: 2, cols: 60, rows: 20),
            passiveA,
            passiveB,
            passiveANewer,
            .mouse(
                button: "left", action: "press", modifier: "",
                grid: 3, row: 2, col: 4, repeatCount: 1),
            activeA,
            .paste("barrier"),
            activeA,
        ]

        let coalesced = commands.reduce(into: [NvimInputCommand]()) { queue, command in
            if let last = queue.last, let merged = last.coalesced(with: command) {
                queue[queue.count - 1] = merged
            } else {
                queue.append(command)
            }
        }

        #expect(coalesced == [
            .resizeGrid(grid: 1, cols: 90, rows: 30),
            .keys("j"),
            .resizeGrid(grid: 1, cols: 100, rows: 32),
            .resizeGrid(grid: 2, cols: 60, rows: 20),
            passiveA,
            passiveB,
            passiveANewer,
            .mouse(
                button: "left", action: "press", modifier: "",
                grid: 3, row: 2, col: 4, repeatCount: 1),
            activeA,
            .paste("barrier"),
            activeA,
        ])
    }
}

// MARK: - Integration against real nvim

private let nvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var nvimAvailable: Bool { FileManager.default.isExecutableFile(atPath: nvimPath) }

@Suite struct NvimIntegrationTests {
    @Test(
        "embedded nvim: attach, redraw, input, bidirectional RPC, clean shutdown",
        .enabled(if: nvimAvailable, "nvim not found at \(nvimPath)"),
        .timeLimit(.minutes(1)))
    func embeddedSession() async throws {
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: nvimPath),
                arguments: ["--embed", "--clean", "-u", "NONE", "-i", "NONE"]))

        // Incoming-request handler must be installed before bytes flow.
        await session.setRequestHandler { method, params in
            if method == "superlemon_ping" {
                return .success(.array([.string("pong")] + params))
            }
            return .failure("unhandled: \(method)")
        }

        let sink = EventSink()
        let pump = Task {
            for await batch in session.uiEvents {
                await sink.add(batch)
            }
        }
        let exitBox = ExitBox()
        let exitWatcher = Task {
            for await event in session.lifecycleEvents {
                await exitBox.set(event)
                break
            }
        }
        defer {
            pump.cancel()
            exitWatcher.cancel()
        }

        try await session.start()

        // Handshake: nvim_get_api_info + nvim_set_client_info.
        let info = try await session.handshake()
        #expect(info.channelID >= 1)
        #expect(info.apiLevel >= 10)  // nvim 0.10+

        // Client info must be visible on our channel.
        let channelInfo = try await session.request(
            "nvim_get_chan_info", [.int(Int64(info.channelID))])
        #expect(channelInfo["client"]?["name"]?.stringValue == "superlemon")

        // Attach with ext_linegrid; the first flushed frame must contain
        // grid_resize and grid_line for the default grid.
        try await session.attachUI(
            width: 80, height: 24,
            options: ["rgb": .bool(true), "ext_linegrid": .bool(true)])

        try await waitUntil {
            await sink.contains { if case .flush = $0 { true } else { false } }
        }
        let resizedTo80x24 = await sink.contains {
            if case .gridResize(grid: 1, width: 80, height: 24) = $0 { return true }
            return false
        }
        #expect(resizedTo80x24, "expected grid_resize for grid 1 at 80x24 before first flush")
        let sawGridLine = await sink.contains {
            if case .gridLine = $0 { return true }
            return false
        }
        #expect(sawGridLine, "expected grid_line events before first flush")

        // Type "hello": fire-and-forget input, then assert it lands on a grid line.
        await session.notify("nvim_input", [.string("ihello<Esc>")])
        try await waitUntil {
            await sink.contains { lineText($0)?.contains("hello") ?? false }
        }

        // Bidirectional RPC: have nvim call back into our request handler.
        let pong = try await session.request(
            "nvim_exec_lua",
            [
                .string("return vim.rpcrequest(..., 'superlemon_ping', 42)"),
                .array([.int(Int64(info.channelID))]),
            ])
        #expect(pong == .array([.string("pong"), .int(42)]))

        // The default handler path: unknown methods produce an RPC error.
        await #expect(throws: NvimError.self) {
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("return vim.rpcrequest(..., 'no_such_method')"),
                    .array([.int(Int64(info.channelID))]),
                ])
        }

        // An invalid API call must surface as a typed RPC error, not a hang.
        await #expect(throws: NvimError.self) {
            _ = try await session.request("nvim_not_a_real_method", [])
        }

        // Clean shutdown: :qa! then a lifecycle exit with status 0.
        await session.notify("nvim_command", [.string("qa!")])
        try await waitUntil { await exitBox.event != nil }
        guard case .exited(let code, _)? = await exitBox.event else {
            Issue.record("expected lifecycle exit event")
            return
        }
        #expect(code == 0)
    }
}
