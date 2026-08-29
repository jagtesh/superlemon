import Foundation

/// Lifecycle of one ControlMaster-backed SSH connection: a pty-wrapped
/// interactive auth channel that establishes a persisted master, plus `-O`
/// control operations and command channels that reuse it without re-auth.
public actor SSHMaster {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case disconnected(exitStatus: Int32?)
    }

    public let endpoint: SSHEndpoint
    private let sshPath: String
    private let stateDirectory: String
    private let pty = PTYProcess()

    public private(set) var state: State = .idle

    public init(
        endpoint: SSHEndpoint,
        sshPath: String = "/usr/bin/ssh",
        stateDirectory: String? = nil
    ) {
        self.endpoint = endpoint
        self.sshPath = sshPath
        // Unix socket paths cap at ~104 bytes and ssh appends a ~17-char
        // temp suffix to ControlPath, so $TMPDIR (/var/folders/…) is too
        // deep on macOS. A short home-relative dir keeps the full path
        // (~/.superlemon/cm-<40-hex>.<suffix>) comfortably under the limit.
        self.stateDirectory =
            stateDirectory
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".superlemon")
    }

    /// Open the auth channel: `ssh -tt <host> -- echo <marker>`. All bytes
    /// (MOTD, banners, auth prompts, finally the ready marker) flow to
    /// `onOutput`; once the marker appears the persisted master is up and
    /// this process exits on its own.
    public func connect(
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        guard state == .idle || isDisconnected else { return }
        try FileManager.default.createDirectory(
            atPath: stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        state = .connecting
        let args = SSHCommandBuilder.masterConnection(
            endpoint: endpoint, stateDirectory: stateDirectory)
        try pty.start(
            executable: sshPath, arguments: args,
            onOutput: onOutput,
            onExit: { [weak self] status in
                Task { await self?.markDisconnected(status: status) }
                onExit(status)
            })
        state = .connected
    }

    /// Keystrokes for interactive auth prompts (password, "yes").
    public func write(_ bytes: [UInt8]) throws {
        try pty.write(bytes)
    }

    /// Run a short-lived `-O` control operation; returns exit status.
    @discardableResult
    public func controlOperation(_ operation: String) async throws -> Int32 {
        let args = SSHCommandBuilder.controlOperation(
            operation, endpoint: endpoint, stateDirectory: stateDirectory)
        return try await Self.runOnce(executable: sshPath, arguments: args)
    }

    /// Is the master alive? (`ssh -O check`)
    public func check() async -> Bool {
        (try? await controlOperation("check")) == 0
    }

    public func disconnect() async {
        _ = try? await controlOperation("exit")
        pty.terminate()
    }

    /// Abort a connection attempt still in the auth pty: kills the local
    /// `ssh -tt` auth process only, and never sends `-O exit`. If the
    /// master had already reached the ready marker (so a persisted
    /// ControlMaster socket exists), that master is left untouched — a
    /// sibling window on the same destination may still be riding it (see
    /// `RemoteMasterRegistry`), and if not, `ControlPersist`'s idle timeout
    /// reclaims it (`SSHEndpoint.masterConnection`).
    public func abortAuth() {
        pty.terminate()
    }

    /// Final process-ownership backstop for app-quit teardown, run from
    /// `applicationWillTerminate` where no `await` is possible: sends
    /// `ssh -O exit` and blocks (bounded by `timeout`) for it to finish,
    /// forcing it down if it hasn't replied in time. Bypasses actor
    /// isolation (`endpoint`/`sshPath`/`stateDirectory` are all immutable
    /// Sendable `let`s) so it can run synchronously on the caller's thread.
    public nonisolated func disconnectSynchronously(timeout: TimeInterval = 2) {
        let args = SSHCommandBuilder.controlOperation(
            "exit", endpoint: endpoint, stateDirectory: stateDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Remote execution over the master (no re-auth)

    /// Run a remote command, optionally feeding stdin; returns exit status.
    @discardableResult
    public func runRemote(_ remoteCommand: [String], stdin: Data? = nil) async throws -> Int32 {
        let args = SSHCommandBuilder.channelCommand(
            endpoint: endpoint, stateDirectory: stateDirectory, remoteCommand: remoteCommand)
        return try await Self.runOnce(executable: sshPath, arguments: args, stdin: stdin)
    }

    /// Run a remote command over the master and return its stdout.
    public func runRemoteCapturing(_ remoteCommand: [String]) async throws -> String {
        let args = SSHCommandBuilder.channelCommand(
            endpoint: endpoint, stateDirectory: stateDirectory, remoteCommand: remoteCommand)
        return try await Self.captureOnce(executable: sshPath, arguments: args)
    }

    /// Copy a local directory's contents to a remote directory (created if
    /// missing) by piping tar through the authenticated master. Paths are
    /// restricted to safe characters because they're interpolated into a
    /// remote shell command.
    public func deployDirectory(localPath: String, remotePath: String) async throws {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._~-")
        guard remotePath.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            throw PTYProcess.PTYError.spawnFailed("unsafe remote path: \(remotePath)")
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-C", localPath, "-cf", "-", "."]
        let pipe = Pipe()
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: sshPath)
        // ATOMIC swap: extract into a staging dir, then mv into place. A
        // direct extract leaves a window where readers (nvim starting up)
        // see a PARTIAL tree — half-deployed runtime crashes nvim at startup.
        ssh.arguments = SSHCommandBuilder.channelCommand(
            endpoint: endpoint, stateDirectory: stateDirectory,
            remoteCommand: [
                "rm -rf \(remotePath).staging && mkdir -p \(remotePath).staging"
                    + " && tar -C \(remotePath).staging -xf -"
                    + " && rm -rf \(remotePath).old"
                    + " && { [ -d \(remotePath) ] && mv \(remotePath) \(remotePath).old || true; }"
                    + " && mv \(remotePath).staging \(remotePath)"
                    + " && rm -rf \(remotePath).old",
            ])
        ssh.standardInput = pipe
        ssh.standardError = FileHandle.nullDevice

        try tar.run()
        try ssh.run()
        let status = await withCheckedContinuation { continuation in
            ssh.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        tar.waitUntilExit()
        guard status == 0 else {
            throw PTYProcess.PTYError.spawnFailed("runtime deploy failed (ssh exit \(status))")
        }
    }

    /// argv for the remote `nvim --embed` RPC channel over this master.
    public nonisolated var sshExecutablePath: String { sshPath }

    public func embeddedNvimArguments(config: RemoteNvimConfig = .editorManaged) -> [String] {
        SSHCommandBuilder.embeddedNvim(
            endpoint: endpoint, stateDirectory: stateDirectory, config: config)
    }

    /// Deploy the selected custom init file to its fixed remote path.
    public func deployCustomInit(_ contents: Data) async throws {
        let status = try await runRemote(
            ["mkdir -p ~/.superlemon && cat > ~/.superlemon/custom-init.lua"],
            stdin: contents)
        guard status == 0 else {
            throw PTYProcess.PTYError.spawnFailed("custom init deploy failed (ssh exit \(status))")
        }
    }

    private func markDisconnected(status: Int32) {
        state = .disconnected(exitStatus: status)
    }

    private var isDisconnected: Bool {
        if case .disconnected = state { return true }
        return false
    }

    private static func runOnce(
        executable: String, arguments: [String], stdin: Data? = nil
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var stdinPipe: Pipe?
            if stdin != nil {
                stdinPipe = Pipe()
                process.standardInput = stdinPipe
            }
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                if let stdin, let stdinPipe {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func captureOnce(executable: String, arguments: [String]) async throws -> String
    {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let buffer = LockedBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    buffer.append(data)
                }
            }
            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.availableData
                if !remaining.isEmpty { buffer.append(remaining) }
                continuation.resume(returning: buffer.string())
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe accumulator for captured stdout.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
