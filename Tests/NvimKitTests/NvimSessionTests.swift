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
        // /bin/cat speaks no msgpack-RPC: the request stays in flight until
        // the process is killed, at which point it must fail.
        let session = NvimSession(
            configuration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/bin/cat"), arguments: []))
        try await session.start()

        let pending = Task { try await session.request("nvim_get_api_info", []) }
        try await Task.sleep(for: .milliseconds(100))
        await session.terminate()

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
}

// MARK: - Integration against real nvim

private let nvimPath = "/opt/homebrew/bin/nvim"
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
