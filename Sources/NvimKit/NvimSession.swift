import Foundation
import os

// MARK: - Launch configuration

public struct NvimLaunchConfiguration: Sendable {
    public var binaryURL: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environment: [String: String]?

    public init(
        binaryURL: URL,
        arguments: [String] = ["--embed"],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.binaryURL = binaryURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

// MARK: - Errors

/// Error string returned by a `requestHandler` to reject a request from nvim.
/// (Swift's `Result` needs an `Error` type, so the plain String is wrapped;
/// `return .failure("nope")` still works via the string literal conformance.)
public struct NvimHandlerError: Error, Sendable, Equatable, ExpressibleByStringLiteral,
    ExpressibleByStringInterpolation
{
    public var message: String
    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { self.message = value }
}

public enum NvimError: Error, Sendable, Equatable {
    /// nvim answered a request with an error response ([type, message] on the wire).
    case rpc(code: Int64?, message: String)
    /// `request`/`attachUI` called before `start()` or after termination.
    case sessionNotRunning
    /// The nvim process exited; all in-flight requests fail with this.
    case sessionTerminated(exitCode: Int32?, stderrTail: String)
    /// The byte stream from nvim could not be parsed.
    case protocolError(String)
    /// `nvim_get_api_info` returned something unexpected.
    case handshakeFailed(String)
}

// MARK: - Session

/// Owns one embedded nvim process: spawns it, speaks msgpack-RPC over its
/// stdin/stdout pipes, decodes `redraw` notifications into typed batches,
/// and reports process death. Pipe reads happen off-actor; only decoded
/// chunks hop into the actor, so the actor never blocks on I/O.
public actor NvimSession {
    public enum LifecycleEvent: Sendable {
        case exited(exitCode: Int32, stderrTail: String)
    }

    /// A non-`redraw` notification from nvim (e.g. `rpcnotify` from the
    /// bundled runtime plugin: "superlemon.status" etc.).
    public struct Notification: Sendable {
        public let method: String
        public let params: [Value]
    }

    /// One fire-and-forget notification destined for nvim. Package scope
    /// keeps the batching surface available to the app without making it part
    /// of NvimKit's public API.
    package struct OutgoingNotification: Sendable, Equatable {
        package let method: String
        package let params: [Value]
        package let repeatCount: Int

        package init(method: String, params: [Value], repeatCount: Int = 1) {
            self.method = method
            self.params = params
            self.repeatCount = max(0, repeatCount)
        }
    }

    /// Decoded `redraw` batches. A batch whose last event is `.flush` is a
    /// complete, presentable frame. Single-consumer.
    public nonisolated let uiEvents: AsyncStream<RedrawBatch>
    /// Process exit notification (exit code + captured stderr tail).
    public nonisolated let lifecycleEvents: AsyncStream<LifecycleEvent>
    /// Every notification that is not `redraw`, in arrival order.
    /// Single-consumer.
    public nonisolated let notifications: AsyncStream<Notification>

    /// Most recent stderr output from the nvim process (bounded ring buffer).
    public nonisolated var stderrTail: String { stderrBuffer.tail }

    /// Handles requests initiated *by nvim* (e.g. the clipboard provider or a
    /// blocking `vimenter` handshake). Returning `.failure` sends an RPC error
    /// response. Defaults to rejecting every method.
    public private(set) var requestHandler:
        @Sendable (String, [Value]) async -> Result<Value, NvimHandlerError> = { method, _ in
            .failure("superlemon: no handler for method '\(method)'")
        }

    public func setRequestHandler(
        _ handler: @escaping @Sendable (String, [Value]) async -> Result<Value, NvimHandlerError>
    ) {
        requestHandler = handler
    }

    private enum State {
        case idle
        case running
        case terminated(Int32?)
    }

    private let configuration: NvimLaunchConfiguration
    private let logger = Logger(subsystem: "dev.superlemon.NvimKit", category: "session")

    private var state: State = .idle
    private var process: Process?
    private var writer: PipeWriter?
    private var stdoutPump: PipePump?
    private var stderrPump: PipePump?
    private var readTask: Task<Void, Never>?
    private nonisolated let stderrBuffer = RingBuffer(capacity: 64 * 1024)

    private var decoder = MsgpackDecoder()
    private var nextMsgid: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<Value, any Error>] = [:]

    private let uiContinuation: AsyncStream<RedrawBatch>.Continuation
    private let lifecycleContinuation: AsyncStream<LifecycleEvent>.Continuation
    private let notificationContinuation: AsyncStream<Notification>.Continuation

    public init(configuration: NvimLaunchConfiguration) {
        self.configuration = configuration
        (uiEvents, uiContinuation) = AsyncStream.makeStream(
            of: RedrawBatch.self, bufferingPolicy: .unbounded)
        (lifecycleEvents, lifecycleContinuation) = AsyncStream.makeStream(
            of: LifecycleEvent.self, bufferingPolicy: .unbounded)
        (notifications, notificationContinuation) = AsyncStream.makeStream(
            of: Notification.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Spawn the nvim process and start pumping its pipes.
    /// Separate from `init` so a `requestHandler` can be installed before any
    /// bytes flow (nvim may send a blocking request during startup).
    public func start() throws {
        guard case .idle = state else { return }

        let process = Process()
        process.executableURL = configuration.binaryURL
        process.arguments = configuration.arguments
        if let cwd = configuration.workingDirectory { process.currentDirectoryURL = cwd }
        if let env = configuration.environment { process.environment = env }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (chunks, chunkContinuation) = AsyncStream.makeStream(
            of: [UInt8].self, bufferingPolicy: .unbounded)
        stdoutPump = PipePump(
            handle: stdoutPipe.fileHandleForReading,
            sink: { chunkContinuation.yield($0) },
            onEOF: { chunkContinuation.finish() })
        let stderrBuffer = stderrBuffer
        stderrPump = PipePump(
            handle: stderrPipe.fileHandleForReading,
            sink: { stderrBuffer.append($0) },
            onEOF: {})

        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { await self?.handleProcessExit(exitCode: code) }
        }

        try process.run()
        self.process = process
        writer = PipeWriter(handle: stdinPipe.fileHandleForWriting)
        state = .running

        readTask = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                await self.ingest(chunk)
            }
            await self?.handleStdoutEOF()
        }
    }

    /// Ask the OS to terminate nvim (SIGTERM). Prefer quitting via
    /// `:confirm qa` semantics; this is the hard-stop path.
    public func terminate() {
        process?.terminate()
    }

    // MARK: RPC

    /// Send a msgpack-RPC request and await the correlated response.
    public func request(_ method: String, _ params: [Value]) async throws -> Value {
        guard case .running = state else { throw notRunningError() }
        let msgid = nextMsgid
        nextMsgid &+= 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[msgid] = continuation
            send(.request(msgid: msgid, method: method, params: params))
        }
    }

    /// Fire-and-forget notification (used for all input).
    public func notify(_ method: String, _ params: [Value]) {
        notifyBatch([.init(method: method, params: params)])
    }

    /// Write an ordered notification batch as one contiguous pipe payload.
    /// MessagePack-RPC is self-framing, so concatenating complete notification
    /// values preserves the exact wire sequence while avoiding one dispatch
    /// and `FileHandle.write` per wheel line.
    package func notifyBatch(_ notifications: [OutgoingNotification]) {
        guard case .running = state, !notifications.isEmpty else { return }

        var frames: [(bytes: [UInt8], count: Int)] = []
        var byteCount = 0
        for notification in notifications {
            guard notification.repeatCount > 0 else { continue }
            let encoded = MsgpackEncoder.encode(
                RPCMessage.notification(
                    method: notification.method,
                    params: notification.params
                ).encoded)
            let (frameBytes, overflow) = encoded.count.multipliedReportingOverflow(
                by: notification.repeatCount)
            guard !overflow else { return }
            let (newByteCount, sumOverflow) = byteCount.addingReportingOverflow(frameBytes)
            guard !sumOverflow else { return }
            byteCount = newByteCount
            frames.append((encoded, notification.repeatCount))
        }
        guard byteCount > 0 else { return }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for frame in frames {
            for _ in 0..<frame.count { bytes.append(contentsOf: frame.bytes) }
        }
        writer?.write(bytes)
    }

    // MARK: Attach & handshake

    /// `nvim_get_api_info` result, condensed.
    public struct APIInfo: Sendable {
        public var channelID: Int
        public var apiLevel: Int
        public var apiCompatible: Int
        public var version: String
    }

    /// Validate the API and introduce ourselves: `nvim_get_api_info` followed
    /// by `nvim_set_client_info` (name "superlemon", type "ui").
    @discardableResult
    public func handshake(
        clientName: String = "superlemon",
        version: (major: Int, minor: Int, patch: Int) = (0, 1, 0)
    ) async throws -> APIInfo {
        let reply = try await request("nvim_get_api_info", [])
        guard let parts = reply.arrayValue, parts.count == 2,
            let channelID = parts[0].intValue,
            let metadata = parts.last, metadata.mapValue != nil
        else { throw NvimError.handshakeFailed("unexpected nvim_get_api_info reply") }

        let versionInfo = metadata["version"]
        let info = APIInfo(
            channelID: channelID,
            apiLevel: versionInfo?["api_level"]?.intValue ?? 0,
            apiCompatible: versionInfo?["api_compatible"]?.intValue ?? 0,
            version: [
                versionInfo?["major"]?.intValue ?? 0,
                versionInfo?["minor"]?.intValue ?? 0,
                versionInfo?["patch"]?.intValue ?? 0,
            ].map(String.init).joined(separator: "."))

        _ = try await request(
            "nvim_set_client_info",
            [
                .string(clientName),
                .map([
                    (.string("major"), .int(Int64(version.major))),
                    (.string("minor"), .int(Int64(version.minor))),
                    (.string("patch"), .int(Int64(version.patch))),
                ]),
                .string("ui"),
                .map([]),
                .map([]),
            ])
        return info
    }

    /// `nvim_ui_attach` with the given grid size and UI options
    /// (e.g. `["rgb": .bool(true), "ext_linegrid": .bool(true)]`).
    public func attachUI(width: Int, height: Int, options: [String: Value] = [:]) async throws {
        let pairs = options
            .sorted { $0.key < $1.key }
            .map { (Value.string($0.key), $0.value) }
        _ = try await request(
            "nvim_ui_attach",
            [.int(Int64(width)), .int(Int64(height)), .map(pairs)])
    }

    // MARK: Incoming bytes

    private func ingest(_ chunk: [UInt8]) {
        decoder.append(chunk)
        while true {
            let value: Value?
            do {
                value = try decoder.decodeNext()
            } catch {
                logger.error("malformed msgpack from nvim: \(String(describing: error), privacy: .public)")
                failSession(with: .protocolError(String(describing: error)))
                process?.terminate()
                return
            }
            guard let value else { return }
            dispatch(value)
        }
    }

    private func dispatch(_ value: Value) {
        let message: RPCMessage
        do {
            message = try RPCMessage(value)
        } catch {
            logger.error("non-RPC message from nvim: \(String(describing: error), privacy: .public)")
            return
        }

        switch message {
        case .response(let msgid, let error, let result):
            guard let continuation = pending.removeValue(forKey: msgid) else {
                logger.error("response for unknown msgid \(msgid)")
                return
            }
            if case .nil = error {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: Self.rpcError(from: error))
            }

        case .notification(let method, let params):
            if method == "redraw" {
                uiContinuation.yield(RedrawDecoder.decode(params))
            } else {
                notificationContinuation.yield(.init(method: method, params: params))
            }

        case .request(let msgid, let method, let params):
            let handler = requestHandler
            Task { [weak self] in
                let result = await handler(method, params)
                await self?.respond(msgid: msgid, result: result)
            }
        }
    }

    private func respond(msgid: UInt32, result: Result<Value, NvimHandlerError>) {
        switch result {
        case .success(let value):
            send(.response(msgid: msgid, error: .nil, result: value))
        case .failure(let error):
            // nvim's error shape: [type, message]; type 0 == Exception.
            send(
                .response(
                    msgid: msgid, error: .array([.int(0), .string(error.message)]), result: .nil))
        }
    }

    private func send(_ message: RPCMessage) {
        writer?.write(MsgpackEncoder.encode(message.encoded))
    }

    private static func rpcError(from error: Value) -> NvimError {
        if let parts = error.arrayValue, parts.count == 2, let message = parts[1].stringValue {
            return .rpc(code: parts[0].intValue.map(Int64.init), message: message)
        }
        if let message = error.stringValue {
            return .rpc(code: nil, message: message)
        }
        return .rpc(code: nil, message: String(describing: error))
    }

    // MARK: Teardown

    private func handleProcessExit(exitCode: Int32) {
        guard case .running = state else { return }
        state = .terminated(exitCode)
        let tail = stderrBuffer.tail
        failInFlight(with: .sessionTerminated(exitCode: exitCode, stderrTail: tail))
        lifecycleContinuation.yield(.exited(exitCode: exitCode, stderrTail: tail))
        lifecycleContinuation.finish()
        writer?.close()
        writer = nil
        // uiEvents finishes on stdout EOF so trailing batches aren't dropped.
    }

    private func handleStdoutEOF() {
        uiContinuation.finish()
        notificationContinuation.finish()
        stdoutPump?.stop()
        stdoutPump = nil
        stderrPump?.stop()
        stderrPump = nil
    }

    private func failSession(with error: NvimError) {
        state = .terminated(nil)
        failInFlight(with: error)
    }

    private func failInFlight(with error: NvimError) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    private func notRunningError() -> NvimError {
        if case .terminated(let code) = state {
            return .sessionTerminated(exitCode: code, stderrTail: stderrBuffer.tail)
        }
        return .sessionNotRunning
    }
}

// MARK: - Pipe plumbing (off-actor)

/// Pushes pipe data to a sink as it arrives. `readabilityHandler` runs on a
/// private serial DispatchQueue, so `sink` calls are ordered.
private final class PipePump: @unchecked Sendable {
    private let handle: FileHandle

    init(
        handle: FileHandle,
        sink: @escaping @Sendable ([UInt8]) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                onEOF()
            } else {
                sink([UInt8](data))
            }
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }
}

/// Serializes writes onto a background queue so the actor never blocks on a
/// full pipe.
private final class PipeWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.superlemon.NvimKit.write")

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ bytes: [UInt8]) {
        queue.async { [handle] in
            try? handle.write(contentsOf: Data(bytes))
        }
    }

    func close() {
        queue.async { [handle] in
            try? handle.close()
        }
    }
}

/// Bounded byte ring for the stderr tail, safe to touch from the pipe's
/// dispatch queue and from actor/nonisolated readers.
private final class RingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var bytes: [UInt8] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ new: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(contentsOf: new)
        if bytes.count > capacity {
            bytes.removeFirst(bytes.count - capacity)
        }
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
