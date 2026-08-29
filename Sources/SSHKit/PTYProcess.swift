import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A child process running under a local pseudo-terminal.
///
/// Interactive ssh auth (via `ssh -tt`) needs a client tty; we hold the
/// master side in raw mode (no echo, no canonical processing) so prompt
/// bytes pass through untouched.
///
/// Spawning goes through `posix_spawn` with `POSIX_SPAWN_SETSID` rather
/// than Foundation's `Process` because the child must acquire the pty
/// slave as its *controlling* terminal. The child is made a fresh session
/// leader with no controlling tty, and then opens the slave **by path**
/// (via a `posix_spawn_file_actions_addopen` on fd 0, without `O_NOCTTY`)
/// — on BSD/Darwin that open is what acquires the controlling terminal,
/// no `TIOCSCTTY` needed. Without this, OpenSSH's `read_passphrase()`
/// can't open `/dev/tty` for host-key confirmation, password auth, or
/// key-passphrase prompts ("Device not configured"), because a
/// `Process`-spawned child that merely has the slave wired to fd 0/1/2
/// never actually acquires it as its controlling tty.
///
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every other fd the parent has
/// open (other sessions' pty masters, ControlMaster sockets, pipes, …) in
/// the child — the same protection Foundation's `Process` gets for free.
/// Without it, a second concurrent `PTYProcess` would leak its ssh child
/// a copy of this one's master fd, and that master would then never see
/// EOF after this session's ssh exits.
public final class PTYProcess: @unchecked Sendable {
    public enum PTYError: Error {
        case openptyFailed(errno: Int32)
        case spawnFailed(String)
        case notRunning
    }

    private var masterHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var childPID: pid_t = -1
    private let stateLock = NSLock()

    public private(set) var isRunning = false

    public init() {}

    /// Spawn `executable` with `arguments`, attached to a fresh pty.
    /// `onOutput` receives master-side bytes; `onExit` fires once on
    /// termination with the exit status.
    public func start(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        initialSize: (rows: UInt16, columns: UInt16) = (24, 80),
        onOutput: @escaping @Sendable ([UInt8]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(
            ws_row: initialSize.rows, ws_col: initialSize.columns, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PTYError.openptyFailed(errno: errno)
        }

        // Raw mode on the pty: no echo, no signals, no canonical editing.
        // This is a device-level (line discipline) setting, so it survives
        // the child re-opening the slave by path below.
        var tio = termios()
        tcgetattr(slave, &tio)
        cfmakeraw(&tio)
        tcsetattr(slave, TCSANOW, &tio)

        // Capture the slave's device path, then drop our fd to it — the
        // child re-opens it itself via file_actions, so we never have to
        // hand a pty fd across the spawn at all.
        guard let slavePathC = ptsname(master) else {
            let failureErrno = errno
            close(master)
            close(slave)
            throw PTYError.spawnFailed("ptsname failed: errno \(failureErrno)")
        }
        let slavePath = String(cString: slavePathC)
        close(slave)

        // Build the C argv/envp.
        var argvPointers: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        for argument in arguments {
            argvPointers.append(strdup(argument))
        }
        argvPointers.append(nil)

        let envDictionary = environment ?? ProcessInfo.processInfo.environment
        var envpPointers: [UnsafeMutablePointer<CChar>?] = envDictionary.map {
            strdup("\($0.key)=\($0.value)")
        }
        envpPointers.append(nil)
        let pathPointer = strdup(executable)

        func freeSpawnBuffers() {
            free(pathPointer)
            for pointer in argvPointers where pointer != nil { free(pointer) }
            for pointer in envpPointers where pointer != nil { free(pointer) }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // Child re-opens the pty slave by path onto fd 0 (this is what
        // acquires the controlling terminal), then mirrors it to 1 and 2.
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(
            &attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = -1
        let spawnStatus: Int32 = argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
            envpPointers.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &pid, pathPointer, &fileActions, &attr, argvBuffer.baseAddress,
                    envpBuffer.baseAddress)
            }
        }
        // posix_spawn returns its error number directly rather than
        // setting errno, so there's no errno to lose to the frees below.
        freeSpawnBuffers()

        guard spawnStatus == 0 else {
            close(master)
            throw PTYError.spawnFailed("posix_spawn failed: errno \(spawnStatus)")
        }

        let master_ = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        masterHandle = master_
        childPID = pid

        master_.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onOutput([UInt8](data))
        }

        isRunning = true
        startWaitingForExit(pid: pid, onExit: onExit)
    }

    private func startWaitingForExit(
        pid: pid_t, onExit: @escaping @Sendable (Int32) -> Void
    ) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitedNormally = (status & 0x7F) == 0
            let code: Int32 =
                exitedNormally
                ? (status >> 8) & 0xFF
                : 128 + (status & 0x7F)

            self?.stateLock.lock()
            self?.isRunning = false
            self?.stateLock.unlock()
            onExit(code)
        }
        source.resume()
        exitSource = source
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let masterHandle, isRunning else { throw PTYError.notRunning }
        try masterHandle.write(contentsOf: Data(bytes))
    }

    public func resize(rows: UInt16, columns: UInt16) {
        guard let masterHandle else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &size)
    }

    public func terminate() {
        guard isRunning, childPID > 0 else { return }
        kill(childPID, SIGTERM)
    }

    public func forceKill() {
        guard isRunning, childPID > 0 else { return }
        kill(childPID, SIGKILL)
    }
}
