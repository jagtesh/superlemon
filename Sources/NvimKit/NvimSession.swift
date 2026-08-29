import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

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

public enum NvimError: LocalizedError, Sendable, Equatable {
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
    /// A request did not receive a response before its explicit deadline.
    case requestTimedOut(method: String)
    /// Writing to nvim's stdin failed.
    case ioFailure(String)
    /// A bounded inbound or outbound queue reached its safety ceiling.
    case backpressureExceeded(channel: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .rpc(let code, let message):
            if let code { return "Neovim RPC error \(code): \(message)" }
            return "Neovim RPC error: \(message)"
        case .sessionNotRunning:
            return "The Neovim session is not running."
        case .sessionTerminated(let exitCode, let stderrTail):
            var description = "The Neovim session terminated"
            if let exitCode { description += " with exit code \(exitCode)" }
            if !stderrTail.isEmpty { description += ": \(stderrTail)" }
            return description + "."
        case .protocolError(let detail):
            return "Neovim sent invalid protocol data: \(detail)"
        case .handshakeFailed(let detail):
            return "Neovim startup validation failed: \(detail)"
        case .requestTimedOut(let method):
            return "Neovim did not answer \(method) before the request deadline."
        case .ioFailure(let detail):
            return "Communication with Neovim failed: \(detail)"
        case .backpressureExceeded(let channel, let limit):
            return "The Neovim \(channel) queue exceeded its \(limit)-item safety limit."
        }
    }
}

/// The exactly-once terminal outcome for a started nvim process.
public struct NvimTermination: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        /// The process exited without NvimKit first requesting shutdown.
        case processExit
        /// A caller requested controlled shutdown.
        case requestedShutdown
        /// Incoming bytes violated MessagePack or RPC framing.
        case protocolError(String)
        /// stdin/stdout transport failed.
        case ioFailure(String)
        /// A bounded stream or write queue could not accept more data safely.
        case backpressureExceeded(channel: String, limit: Int)
    }

    public let cause: Cause
    public let exitCode: Int32?
    public let stderrTail: String
    public let didForceKill: Bool

    public init(
        cause: Cause,
        exitCode: Int32?,
        stderrTail: String,
        didForceKill: Bool
    ) {
        self.cause = cause
        self.exitCode = exitCode
        self.stderrTail = stderrTail
        self.didForceKill = didForceKill
    }
}

/// A bounded, lossless, single-consumer event stream.
///
/// Producers suspend when `capacity` elements are buffered. NvimSession uses
/// that suspension to stop scheduling the next stdout read, allowing the OS
/// pipe to propagate backpressure to Neovim without dropping protocol events.
public struct NvimEventStream<Element: Sendable>: AsyncSequence, Sendable {
    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let storage: NvimEventStreamStorage<Element>

        public mutating func next() async -> Element? {
            await storage.next()
        }
    }

    private let storage: NvimEventStreamStorage<Element>

    fileprivate init(capacity: Int) {
        storage = NvimEventStreamStorage(capacity: capacity)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }

    fileprivate func send(_ element: Element) async -> Bool {
        await storage.send(element)
    }

    fileprivate func finish() {
        storage.finish()
    }
}

private final class NvimEventStreamStorage<Element: Sendable>: @unchecked Sendable {
    private struct WaitingProducer {
        let id: UUID
        let element: Element
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct WaitingConsumer {
        let id: UUID
        let continuation: CheckedContinuation<Element?, Never>
    }

    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [Element] = []
    private var waitingProducers: [WaitingProducer] = []
    private var waitingConsumers: [WaitingConsumer] = []
    private var cancelledProducerIDs: Set<UUID> = []
    private var cancelledConsumerIDs: Set<UUID> = []
    private var finished = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        buffer.reserveCapacity(self.capacity)
    }

    func send(_ element: Element) async -> Bool {
        if Task.isCancelled { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueProducer(id: id, element: element, continuation: continuation)
            }
        } onCancel: {
            cancelProducer(id: id)
        }
    }

    func next() async -> Element? {
        if Task.isCancelled { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueConsumer(id: id, continuation: continuation)
            }
        } onCancel: {
            cancelConsumer(id: id)
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let producers = waitingProducers
        waitingProducers.removeAll()
        let consumers: [WaitingConsumer]
        if buffer.isEmpty {
            consumers = waitingConsumers
            waitingConsumers.removeAll()
        } else {
            consumers = []
        }
        lock.unlock()

        for producer in producers { producer.continuation.resume(returning: false) }
        for consumer in consumers { consumer.continuation.resume(returning: nil) }
    }

    private func enqueueProducer(
        id: UUID,
        element: Element,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        lock.lock()
        if cancelledProducerIDs.remove(id) != nil || finished {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        if !waitingConsumers.isEmpty {
            let consumer = waitingConsumers.removeFirst()
            lock.unlock()
            consumer.continuation.resume(returning: element)
            continuation.resume(returning: true)
            return
        }
        if buffer.count < capacity {
            buffer.append(element)
            lock.unlock()
            continuation.resume(returning: true)
            return
        }
        waitingProducers.append(
            WaitingProducer(id: id, element: element, continuation: continuation))
        lock.unlock()
    }

    private func enqueueConsumer(
        id: UUID,
        continuation: CheckedContinuation<Element?, Never>
    ) {
        lock.lock()
        if cancelledConsumerIDs.remove(id) != nil {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            let producer = waitingProducers.isEmpty ? nil : waitingProducers.removeFirst()
            if let producer { buffer.append(producer.element) }
            lock.unlock()
            producer?.continuation.resume(returning: true)
            continuation.resume(returning: element)
            return
        }
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        waitingConsumers.append(WaitingConsumer(id: id, continuation: continuation))
        lock.unlock()
    }

    private func cancelProducer(id: UUID) {
        lock.lock()
        if let index = waitingProducers.firstIndex(where: { $0.id == id }) {
            let producer = waitingProducers.remove(at: index)
            lock.unlock()
            producer.continuation.resume(returning: false)
        } else {
            cancelledProducerIDs.insert(id)
            lock.unlock()
        }
    }

    private func cancelConsumer(id: UUID) {
        lock.lock()
        if let index = waitingConsumers.firstIndex(where: { $0.id == id }) {
            let consumer = waitingConsumers.remove(at: index)
            lock.unlock()
            consumer.continuation.resume(returning: nil)
        } else {
            cancelledConsumerIDs.insert(id)
            lock.unlock()
        }
    }
}

// MARK: - Session

/// Owns one embedded nvim process: spawns it, speaks msgpack-RPC over its
/// stdin/stdout pipes, decodes `redraw` notifications into typed batches,
/// and reports process death. Pipe reads happen off-actor; only decoded
/// chunks hop into the actor, so the actor never blocks on I/O.
public actor NvimSession {
    /// Backwards-compatible process-exit event. New integrations that need
    /// protocol/I/O causes should consume `terminationEvents` instead.
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
    public nonisolated let uiEvents: NvimEventStream<RedrawBatch>
    /// Process exit notification (exit code + captured stderr tail).
    public nonisolated let lifecycleEvents: AsyncStream<LifecycleEvent>
    /// Rich terminal outcome, emitted exactly once for every successfully
    /// started process, including protocol-triggered termination.
    public nonisolated let terminationEvents: AsyncStream<NvimTermination>
    /// Every notification that is not `redraw`, in arrival order.
    /// Single-consumer.
    public nonisolated let notifications: NvimEventStream<Notification>

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
        case stopping
        case terminated(NvimTermination)
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Value, any Error>
        let signpostID: OSSignpostID
        var timeoutTask: Task<Void, Never>?
    }

    private static let uiBufferLimit = 8
    private static let notificationBufferLimit = 64
    private static let maximumOutgoingBytes = 64 * 1024 * 1024

    private let configuration: NvimLaunchConfiguration
    private let logger = Logger(subsystem: "dev.superlemon.NvimKit", category: "session")
    private let performanceLog = OSLog(
        subsystem: "dev.superlemon.NvimKit", category: "performance")
    private let processReference = ProcessReference()

    private var state: State = .idle
    private var process: Process?
    private var writer: PipeWriter?
    private var stdoutPump: PipePump?
    private var stderrPump: PipePump?
    private nonisolated let stderrBuffer = RingBuffer(capacity: 64 * 1024)

    private var decoder: MsgpackDecoder
    private var nextMsgid: UInt32 = 0
    private var pending: [UInt32: PendingRequest] = [:]
    private var primaryTerminationCause: NvimTermination.Cause?
    private var primaryFailure: NvimError?
    private var didForceKill = false
    private var escalationTask: Task<Void, Never>?
    private var stdoutEOFProbeTask: Task<Void, Never>?
    private var terminationWaiters: [CheckedContinuation<NvimTermination, Never>] = []
    private var dataStreamsFinished = false
    private var processExitObserved = false
    private var suppressProcessExitHandlingForTesting = false

    private let lifecycleContinuation: AsyncStream<LifecycleEvent>.Continuation
    private let terminationContinuation: AsyncStream<NvimTermination>.Continuation

    public init(
        configuration: NvimLaunchConfiguration,
        decodingLimits: MsgpackDecodingLimits = .init()
    ) {
        self.configuration = configuration
        decoder = MsgpackDecoder(limits: decodingLimits)
        uiEvents = NvimEventStream(capacity: Self.uiBufferLimit)
        (lifecycleEvents, lifecycleContinuation) = AsyncStream.makeStream(
            of: LifecycleEvent.self, bufferingPolicy: .bufferingOldest(1))
        (terminationEvents, terminationContinuation) = AsyncStream.makeStream(
            of: NvimTermination.self, bufferingPolicy: .bufferingOldest(1))
        notifications = NvimEventStream(capacity: Self.notificationBufferLimit)
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

        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { await self?.handleProcessExit(exitCode: code) }
        }

        try process.run()
        self.process = process
        processReference.set(process)
        writer = PipeWriter(
            handle: stdinPipe.fileHandleForWriting,
            maximumFrameBytes: Self.maximumOutgoingBytes,
            maximumQueuedBytes: Self.maximumOutgoingBytes,
            performanceLog: performanceLog,
            onFailure: { [weak self] message in
                Task { await self?.handleWriterFailure(message) }
            })
        stdoutPump = PipePump(
            handle: stdoutPipe.fileHandleForReading,
            label: "dev.superlemon.NvimKit.stdout",
            sink: { [weak self] chunk in
                await self?.ingest(chunk)
            },
            onEOF: { [weak self] in
                await self?.handleStdoutEOF()
            },
            onFailure: { [weak self] message in
                await self?.handleReaderFailure("stdout: \(message)")
            })
        let stderrBuffer = stderrBuffer
        stderrPump = PipePump(
            handle: stderrPipe.fileHandleForReading,
            label: "dev.superlemon.NvimKit.stderr",
            sink: { chunk in stderrBuffer.append(chunk) },
            onEOF: {},
            onFailure: { [weak self] message in
                await self?.handleReaderFailure("stderr: \(message)")
            })
        state = .running
        stdoutPump?.start()
        stderrPump?.start()
    }

    /// Begin controlled shutdown. This compatibility entry point returns
    /// immediately; `shutdown` should be preferred when the caller must wait
    /// for the child to be reaped.
    public func terminate() {
        beginStopping(
            cause: .requestedShutdown,
            failure: nil,
            termGrace: .seconds(1),
            killGrace: .seconds(1))
    }

    /// Send SIGTERM, escalate to SIGKILL after `termGrace`, then allow
    /// `killGrace` for Process to report the child reaped. If that final
    /// deadline expires, return a terminal outcome with a nil exit code rather
    /// than stranding shutdown waiters. Concurrent callers share one outcome.
    public func shutdown(
        termGrace: Duration = .seconds(1),
        killGrace: Duration = .seconds(1)
    ) async -> NvimTermination {
        switch state {
        case .terminated(let outcome):
            return outcome
        case .idle:
            // No process was ever started, so there is no lifecycle event to
            // emit and no child to reap.
            return NvimTermination(
                cause: .requestedShutdown,
                exitCode: nil,
                stderrTail: stderrBuffer.tail,
                didForceKill: false)
        case .running, .stopping:
            beginStopping(
                cause: .requestedShutdown,
                failure: nil,
                termGrace: termGrace,
                killGrace: killGrace)
            return await withCheckedContinuation { continuation in
                terminationWaiters.append(continuation)
            }
        }
    }

    /// Synchronous application-termination backstop. The normal path should
    /// use `shutdown`; this method exists for a process that is being torn down
    /// before async cleanup can run.
    public nonisolated func forceKillNow() {
        guard processReference.forceKill() else { return }
        Task { await self.noteForcedKill() }
    }

    /// Test seam for exercising the bounded post-SIGKILL reap deadline without
    /// relying on an OS process that can actually ignore SIGKILL.
    package func suppressProcessExitHandling() {
        suppressProcessExitHandlingForTesting = true
    }

    // MARK: RPC

    /// Send a msgpack-RPC request and await the correlated response.
    ///
    /// Cancellation and timeout both atomically remove the request from the
    /// correlation table. A late response is ignored and cannot resume the
    /// continuation a second time.
    public func request(
        _ method: String,
        _ params: [Value],
        timeout: Duration = .seconds(10)
    ) async throws -> Value {
        guard case .running = state else { throw notRunningError() }
        let msgid = nextMsgid
        nextMsgid &+= 1
        let signpostID = OSSignpostID(log: performanceLog)
        os_signpost(
            .begin,
            log: performanceLog,
            name: "RPC Request",
            signpostID: signpostID,
            "method=%{public}@ id=%u",
            method,
            msgid)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expireRequest(msgid: msgid, method: method)
                }
                pending[msgid] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    signpostID: signpostID,
                    timeoutTask: timeoutTask)

                if let error = enqueue(
                    .request(msgid: msgid, method: method, params: params))
                {
                    completeRequest(msgid: msgid, with: .failure(error))
                    beginFailure(error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(msgid: msgid) }
        }
    }

    /// Visible to package tests and diagnostics without exposing the pending
    /// continuations themselves.
    package var pendingRequestCount: Int { pending.count }

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
            guard !sumOverflow, newByteCount <= Self.maximumOutgoingBytes else {
                beginFailure(
                    .backpressureExceeded(
                        channel: "stdin frame", limit: Self.maximumOutgoingBytes))
                return
            }
            byteCount = newByteCount
            frames.append((encoded, notification.repeatCount))
        }
        guard byteCount > 0 else { return }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        for frame in frames {
            for _ in 0..<frame.count { bytes.append(contentsOf: frame.bytes) }
        }
        if let error = enqueue(bytes) { beginFailure(error) }
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
        version: (major: Int, minor: Int, patch: Int) = (0, 1, 0),
        timeout: Duration = .seconds(10)
    ) async throws -> APIInfo {
        let reply = try await request("nvim_get_api_info", [], timeout: timeout)
        guard let parts = reply.arrayValue, parts.count == 2,
            let channelID = parts[0].intValue,
            let metadata = parts.last, metadata.mapValue != nil
        else { throw NvimError.handshakeFailed("unexpected nvim_get_api_info reply") }

        let versionInfo = metadata["version"]
        let apiLevel = versionInfo?["api_level"]?.intValue ?? 0
        let apiCompatible = versionInfo?["api_compatible"]?.intValue ?? 0
        let major = versionInfo?["major"]?.intValue ?? 0
        let minor = versionInfo?["minor"]?.intValue ?? 0
        let patch = versionInfo?["patch"]?.intValue ?? 0
        let nvimVersion = [major, minor, patch]
            .map { String($0) }
            .joined(separator: ".")
        let info = APIInfo(
            channelID: channelID,
            apiLevel: apiLevel,
            apiCompatible: apiCompatible,
            version: nvimVersion)

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
            ],
            timeout: timeout)
        return info
    }

    /// `nvim_ui_attach` with the given grid size and UI options
    /// (e.g. `["rgb": .bool(true), "ext_linegrid": .bool(true)]`).
    public func attachUI(
        width: Int,
        height: Int,
        options: [String: Value] = [:],
        timeout: Duration = .seconds(5)
    ) async throws {
        let pairs = options
            .sorted { $0.key < $1.key }
            .map { (Value.string($0.key), $0.value) }
        _ = try await request(
            "nvim_ui_attach",
            [.int(Int64(width)), .int(Int64(height)), .map(pairs)],
            timeout: timeout)
    }

    // MARK: Incoming bytes

    private func ingest(_ chunk: [UInt8]) async {
        guard case .running = state else { return }
        os_signpost(
            .event,
            log: performanceLog,
            name: "Inbound Chunk",
            "bytes=%{public}ld",
            chunk.count)
        decoder.append(chunk)
        while true {
            let value: Value?
            do {
                let signpostID = OSSignpostID(log: performanceLog)
                os_signpost(
                    .begin,
                    log: performanceLog,
                    name: "MessagePack Decode",
                    signpostID: signpostID,
                    "pending=%{public}ld",
                    decoder.bytesPending)
                defer {
                    os_signpost(
                        .end,
                        log: performanceLog,
                        name: "MessagePack Decode",
                        signpostID: signpostID,
                        "pending=%{public}ld",
                        decoder.bytesPending)
                }
                value = try decoder.decodeNext()
            } catch {
                logger.error("malformed msgpack from nvim: \(String(describing: error), privacy: .public)")
                beginFailure(.protocolError(String(describing: error)))
                return
            }
            guard let value else { return }
            await dispatch(value)
            guard case .running = state else { return }
        }
    }

    private func dispatch(_ value: Value) async {
        let message: RPCMessage
        do {
            message = try RPCMessage(value)
        } catch {
            let detail = Self.rpcFramingDetail(error)
            logger.error("invalid msgpack-RPC frame from nvim: \(detail, privacy: .public)")
            beginFailure(.protocolError(detail))
            return
        }

        switch message {
        case .response(let msgid, let error, let result):
            guard pending[msgid] != nil else {
                logger.error("response for unknown msgid \(msgid)")
                return
            }
            if case .nil = error {
                completeRequest(msgid: msgid, with: .success(result))
            } else {
                completeRequest(
                    msgid: msgid,
                    with: .failure(Self.rpcError(from: error)))
            }

        case .notification(let method, let params):
            if method == "redraw" {
                _ = await uiEvents.send(RedrawDecoder.decode(params))
            } else {
                _ = await notifications.send(.init(method: method, params: params))
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
        guard case .running = state else { return }
        switch result {
        case .success(let value):
            if let error = enqueue(.response(msgid: msgid, error: .nil, result: value)) {
                beginFailure(error)
            }
        case .failure(let error):
            // nvim's error shape: [type, message]; type 0 == Exception.
            if let error = enqueue(
                .response(
                    msgid: msgid,
                    error: .array([.int(0), .string(error.message)]),
                    result: .nil))
            {
                beginFailure(error)
            }
        }
    }

    private func enqueue(_ message: RPCMessage) -> NvimError? {
        enqueue(MsgpackEncoder.encode(message.encoded))
    }

    private func enqueue(_ bytes: [UInt8]) -> NvimError? {
        guard let writer else { return .ioFailure("stdin writer is closed") }
        switch writer.write(bytes) {
        case .success:
            return nil
        case .failure(.frameTooLarge(let limit)):
            return .backpressureExceeded(channel: "stdin frame", limit: limit)
        case .failure(.queueFull(let limit)):
            return .backpressureExceeded(channel: "stdin queue", limit: limit)
        case .failure(.closed):
            return .ioFailure("stdin writer is closed")
        }
    }

    private func completeRequest(
        msgid: UInt32,
        with result: Result<Value, any Error>
    ) {
        guard let request = pending.removeValue(forKey: msgid) else { return }
        request.timeoutTask?.cancel()
        let resultName: String
        switch result {
        case .success(let value):
            resultName = "success"
            request.continuation.resume(returning: value)
        case .failure(let error):
            if error is CancellationError {
                resultName = "cancelled"
            } else if let nvimError = error as? NvimError,
                case .requestTimedOut = nvimError
            {
                resultName = "timeout"
            } else {
                resultName = "failure"
            }
            request.continuation.resume(throwing: error)
        }
        os_signpost(
            .end,
            log: performanceLog,
            name: "RPC Request",
            signpostID: request.signpostID,
            "method=%{public}@ result=%{public}@",
            request.method,
            resultName)
    }

    private func expireRequest(msgid: UInt32, method: String) {
        completeRequest(
            msgid: msgid,
            with: .failure(NvimError.requestTimedOut(method: method)))
    }

    private func cancelRequest(msgid: UInt32) {
        completeRequest(msgid: msgid, with: .failure(CancellationError()))
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

    private static func rpcFramingDetail(_ error: any Error) -> String {
        guard let framing = error as? RPCFramingError else {
            return String(describing: error)
        }
        switch framing {
        case .notAnRPCMessage:
            return "notAnRPCMessage"
        case .malformedMessage:
            return "malformedMessage"
        case .unknownMessageType(let kind):
            return "unknownMessageType(\(kind))"
        }
    }

    // MARK: Teardown

    private func handleProcessExit(exitCode: Int32) async {
        guard !suppressProcessExitHandlingForTesting else { return }
        if case .terminated = state { return }
        processExitObserved = true
        stdoutEOFProbeTask?.cancel()
        stdoutEOFProbeTask = nil

        // Process termination closes both pipe writers, but their private read
        // queues may still hold the final chunk. Give them a bounded window to
        // reach EOF so the last redraw and stderr diagnostics are not lost.
        // The window only elapses in full when something (e.g. a grandchild)
        // holds the pipe open — EOF completes the wait immediately — so it is
        // sized for loaded CI machines, where 250ms of scheduling delay was
        // enough to lose the exit diagnostics.
        if let stdoutPump {
            let drained = await stdoutPump.waitForCompletion(timeout: .seconds(2))
            if !drained { logger.warning("timed out draining nvim stdout after exit") }
        }
        if let stderrPump {
            let drained = await stderrPump.waitForCompletion(timeout: .seconds(2))
            if !drained { logger.warning("timed out draining nvim stderr after exit") }
        }
        finish(exitCode: exitCode)
    }

    private func finish(exitCode: Int32?) {
        if case .terminated = state { return }
        escalationTask?.cancel()
        escalationTask = nil
        stdoutEOFProbeTask?.cancel()
        stdoutEOFProbeTask = nil

        let outcome = NvimTermination(
            cause: primaryTerminationCause ?? .processExit,
            exitCode: exitCode,
            stderrTail: stderrBuffer.tail,
            didForceKill: didForceKill)
        state = .terminated(outcome)
        processReference.clear()

        let terminalError = primaryFailure
            ?? .sessionTerminated(exitCode: exitCode, stderrTail: outcome.stderrTail)
        failInFlight(with: terminalError)
        finishDataStreams()

        writer?.close()
        writer = nil
        stdoutPump?.stop()
        stdoutPump = nil
        stderrPump?.stop()
        stderrPump = nil
        process = nil

        if let exitCode {
            _ = lifecycleContinuation.yield(
                .exited(exitCode: exitCode, stderrTail: outcome.stderrTail))
        }
        lifecycleContinuation.finish()
        _ = terminationContinuation.yield(outcome)
        terminationContinuation.finish()

        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func beginFailure(_ error: NvimError) {
        let cause: NvimTermination.Cause
        switch error {
        case .protocolError(let message):
            cause = .protocolError(message)
        case .ioFailure(let message):
            cause = .ioFailure(message)
        case .backpressureExceeded(let channel, let limit):
            cause = .backpressureExceeded(channel: channel, limit: limit)
        default:
            cause = .ioFailure(String(describing: error))
        }

        failInFlight(with: error)
        finishDataStreams()
        writer?.close()
        writer = nil
        stdoutPump?.stop()
        stdoutPump = nil
        beginStopping(
            cause: cause,
            failure: error,
            termGrace: .seconds(1),
            killGrace: .seconds(1))
    }

    private func beginStopping(
        cause: NvimTermination.Cause,
        failure: NvimError?,
        termGrace: Duration,
        killGrace: Duration
    ) {
        switch state {
        case .idle, .terminated:
            return
        case .running:
            state = .stopping
        case .stopping:
            break
        }

        if processExitObserved {
            // The process is already gone — `handleProcessExit` is mid-drain
            // and will call `finish` once it completes. A `shutdown()` /
            // `terminate()` call racing that drain must not relabel the real
            // exit (e.g. as `.requestedShutdown`), and there is no live
            // process left to signal, so there is nothing more to do here.
            return
        }

        if primaryTerminationCause == nil { primaryTerminationCause = cause }
        if primaryFailure == nil { primaryFailure = failure }

        guard escalationTask == nil else { return }
        if process?.isRunning == true { process?.terminate() }
        escalationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: termGrace)
            } catch {
                return
            }
            await self?.escalateToSIGKILL(after: killGrace)
        }
    }

    private func escalateToSIGKILL(after killGrace: Duration) async {
        guard case .stopping = state else { return }
        let process = process
        if let process, process.isRunning {
#if canImport(Darwin)
            let signalSent = Darwin.kill(process.processIdentifier, SIGKILL) == 0
#else
            process.terminate()
            let signalSent = true
#endif
            didForceKill = didForceKill || signalSent
        }

        // SIGKILL cannot be caught, but Process callback/reaping bugs must not
        // strand application termination forever. This is a real final
        // deadline: the callback wins if it arrives; otherwise synthesize one
        // nil-exit-code outcome and ignore any callback that arrives later.
        do {
            try await Task.sleep(for: killGrace)
        } catch {
            return
        }
        guard case .stopping = state else { return }
        logger.fault("nvim did not report reaped before the post-SIGKILL deadline")
        let observedExitCode: Int32?
        if let process, !process.isRunning {
            observedExitCode = process.terminationStatus
        } else {
            observedExitCode = nil
        }
        finish(exitCode: observedExitCode)
    }

    private func noteForcedKill() {
        didForceKill = true
    }

    private func handleWriterFailure(_ message: String) {
        guard case .running = state else { return }
        guard !processExitObserved else {
            // The process already exited and `handleProcessExit` is mid-drain
            // (waiting on the stdout/stderr pumps). A queued write hitting
            // EPIPE here is just the pipe closing behind an already-dead
            // process, not a genuine transport failure — relabeling a clean
            // exit as `.ioFailure` and short-circuiting the drain via
            // `beginFailure`/`finishDataStreams()` would both misreport the
            // cause and risk dropping the final redraw batch. Stop accepting
            // further writes and let the drain finish on its own.
            writer?.close()
            return
        }
        beginFailure(.ioFailure(message))
    }

    private func handleReaderFailure(_ message: String) {
        guard case .running = state else { return }
        guard !processExitObserved else {
            // Same rationale as `handleWriterFailure`: the process already
            // exited, so a reader failure here is expected pipe teardown
            // during the drain, not a genuine I/O error worth reporting.
            return
        }
        beginFailure(.ioFailure(message))
    }

    private func handleStdoutEOF() {
        finishDataStreams()
        stdoutPump?.stop()
        stdoutPump = nil

        guard case .running = state, !processExitObserved else { return }
        stdoutEOFProbeTask?.cancel()
        stdoutEOFProbeTask = Task { [weak self] in
            await self?.probeStdoutClosedWhileLive()
        }
    }

    /// `Process.terminationHandler` can lag stdout EOF by more than the
    /// original fixed 50ms wait on a loaded machine (250ms of scheduling
    /// delay has been observed in CI) — closing stdout is the first thing
    /// that happens on exit, and the kernel reaping the child and Foundation
    /// invoking the callback both come after. Polling in short steps for up
    /// to ~1s gives that reap time to land, while still bailing out the
    /// moment `processExitObserved` flips so a normal exit isn't held up
    /// waiting out the whole window.
    private func probeStdoutClosedWhileLive() async {
        for _ in 0..<20 {
            guard case .running = state, !processExitObserved else {
                stdoutEOFProbeTask = nil
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                stdoutEOFProbeTask = nil
                return
            }
        }
        failIfStdoutClosedWhileLive()
    }

    private func failIfStdoutClosedWhileLive() {
        stdoutEOFProbeTask = nil
        guard case .running = state, !processExitObserved,
            process?.isRunning == true
        else { return }
        beginFailure(.ioFailure("stdout closed while nvim process was still running"))
    }

    private func finishDataStreams() {
        guard !dataStreamsFinished else { return }
        dataStreamsFinished = true
        uiEvents.finish()
        notifications.finish()
    }

    private func failInFlight(with error: NvimError) {
        let ids = Array(pending.keys)
        for id in ids { completeRequest(msgid: id, with: .failure(error)) }
    }

    private func notRunningError() -> NvimError {
        if case .terminated(let outcome) = state {
            if let primaryFailure { return primaryFailure }
            return .sessionTerminated(
                exitCode: outcome.exitCode,
                stderrTail: outcome.stderrTail)
        }
        return .sessionNotRunning
    }
}

// MARK: - Pipe plumbing (off-actor)

/// Reads one fixed-size chunk at a time and does not schedule the next read
/// until the async sink has consumed the current one. The pipe therefore
/// supplies lossless OS-level backpressure instead of an unbounded byte queue.
private final class PipePump: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let sink: @Sendable ([UInt8]) async -> Void
    private let onEOF: @Sendable () async -> Void
    private let onFailure: @Sendable (String) async -> Void
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var completed = false
    private var completionWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(
        handle: FileHandle,
        label: String,
        sink: @escaping @Sendable ([UInt8]) async -> Void,
        onEOF: @escaping @Sendable () async -> Void,
        onFailure: @escaping @Sendable (String) async -> Void
    ) {
        self.handle = handle
        queue = DispatchQueue(label: label)
        self.sink = sink
        self.onEOF = onEOF
        self.onFailure = onFailure
    }

    func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        scheduleRead()
    }

    func stop() {
        lock.lock()
        let shouldClose = !stopped
        stopped = true
        lock.unlock()
        if shouldClose { try? handle.close() }
        complete()
    }

    /// Wait until EOF/failure has run through the async sink. The timeout is
    /// implemented inside the pump so abandoning the wait cannot strand a
    /// continuation or hold up actor teardown.
    func waitForCompletion(timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            completionWaiters[id] = continuation
            lock.unlock()

            Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.expireCompletionWaiter(id)
            }
        }
    }

    private func scheduleRead() {
        queue.async { [weak self] in self?.readOne() }
    }

    private func readOne() {
        guard !isStopped else { return }
        do {
            let bytes = try readAvailableChunk()
            guard !bytes.isEmpty else {
                guard markStopped() else { return }
                Task { [weak self] in
                    await self?.onEOF()
                    self?.complete()
                }
                return
            }
            Task { [weak self] in
                guard let self else { return }
                await sink(bytes)
                guard !isStopped else { return }
                scheduleRead()
            }
        } catch {
            let shouldReport = markStopped()
            if shouldReport {
                let message = String(describing: error)
                Task { [weak self] in
                    await self?.onFailure(message)
                    self?.complete()
                }
            }
        }
    }

    private func readAvailableChunk() throws -> [UInt8] {
#if canImport(Darwin)
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { storage in
                Darwin.read(handle.fileDescriptor, storage.baseAddress, storage.count)
            }
            if count > 0 {
                bytes.removeSubrange(count..<bytes.count)
                return bytes
            }
            if count == 0 { return [] }
            if errno == EINTR { continue }
            throw POSIXReadError(code: errno)
        }
#else
        return [UInt8](try handle.readToEnd() ?? Data())
#endif
    }

    @discardableResult
    private func markStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        stopped = true
        return true
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func complete() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let waiters = Array(completionWaiters.values)
        completionWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: true) }
    }

    private func expireCompletionWaiter(_ id: UUID) {
        lock.lock()
        let waiter = completionWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(returning: false)
    }
}

private struct POSIXReadError: Error, CustomStringConvertible, Sendable {
    let code: Int32

    var description: String {
#if canImport(Darwin)
        String(cString: strerror(code))
#else
        "pipe read failed (errno \(code))"
#endif
    }
}

/// Serializes writes onto a background queue so the actor never blocks on a
/// full pipe. Admission is byte-bounded and asynchronous errors are reported
/// back to the owning session exactly once.
private final class PipeWriter: @unchecked Sendable {
    enum EnqueueError: Error {
        case frameTooLarge(limit: Int)
        case queueFull(limit: Int)
        case closed
    }

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dev.superlemon.NvimKit.write")
    private let lock = NSLock()
    private let maximumFrameBytes: Int
    private let maximumQueuedBytes: Int
    private let performanceLog: OSLog
    private let onFailure: @Sendable (String) -> Void
    private var queuedBytes = 0
    private var acceptingWrites = true
    private var failed = false
    private var closeScheduled = false

    init(
        handle: FileHandle,
        maximumFrameBytes: Int,
        maximumQueuedBytes: Int,
        performanceLog: OSLog,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.handle = handle
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumQueuedBytes = maximumQueuedBytes
        self.performanceLog = performanceLog
        self.onFailure = onFailure
#if canImport(Darwin)
        // FileHandle writes ultimately call write(2), whose default behavior
        // is to terminate the entire process with SIGPIPE when the child has
        // already closed stdin. Convert that condition into EPIPE so the
        // throwing FileHandle API can report it normally instead.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
    }

    func write(_ bytes: [UInt8]) -> Result<Void, EnqueueError> {
        guard bytes.count <= maximumFrameBytes else {
            return .failure(.frameTooLarge(limit: maximumFrameBytes))
        }

        lock.lock()
        guard acceptingWrites else {
            lock.unlock()
            return .failure(.closed)
        }
        guard bytes.count <= maximumQueuedBytes - queuedBytes else {
            lock.unlock()
            return .failure(.queueFull(limit: maximumQueuedBytes))
        }
        queuedBytes += bytes.count
        let currentQueuedBytes = queuedBytes
        lock.unlock()

        os_signpost(
            .event,
            log: performanceLog,
            name: "Writer Queue Depth",
            "bytes=%{public}ld",
            currentQueuedBytes)

        queue.async { [weak self] in self?.performWrite(bytes) }
        return .success(())
    }

    func close() {
        lock.lock()
        acceptingWrites = false
        let shouldClose = !closeScheduled
        closeScheduled = true
        lock.unlock()
        guard shouldClose else { return }
        queue.async { [handle] in try? handle.close() }
    }

    private func performWrite(_ bytes: [UInt8]) {
        lock.lock()
        let shouldWrite = !failed
        lock.unlock()
        guard shouldWrite else {
            release(bytes.count)
            return
        }

        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 64 * 1024, bytes.count)
                try handle.write(contentsOf: Data(bytes[offset..<end]))
                offset = end
            }
            release(bytes.count)
        } catch {
            lock.lock()
            queuedBytes = max(0, queuedBytes - bytes.count)
            let currentQueuedBytes = queuedBytes
            let shouldReport = !failed
            failed = true
            acceptingWrites = false
            lock.unlock()
            os_signpost(
                .event,
                log: performanceLog,
                name: "Writer Queue Depth",
                "bytes=%{public}ld",
                currentQueuedBytes)
            if shouldReport { onFailure(String(describing: error)) }
        }
    }

    private func release(_ count: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - count)
        let currentQueuedBytes = queuedBytes
        lock.unlock()
        os_signpost(
            .event,
            log: performanceLog,
            name: "Writer Queue Depth",
            "bytes=%{public}ld",
            currentQueuedBytes)
    }
}

/// Locked process reference used only by the synchronous final-termination
/// backstop. Normal lifecycle management remains actor-isolated.
private final class ProcessReference: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func forceKill() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
#if canImport(Darwin)
        return Darwin.kill(process.processIdentifier, SIGKILL) == 0
#else
        process.terminate()
        return true
#endif
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
