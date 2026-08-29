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
public final class PTYProcess: @unchecked Sendable {
    public enum PTYError: Error {
        case openptyFailed(errno: Int32)
        case spawnFailed(String)
        case notRunning
    }

    private let process = Process()
    private var masterHandle: FileHandle?
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
        var tio = termios()
        tcgetattr(slave, &tio)
        cfmakeraw(&tio)
        tcsetattr(slave, TCSANOW, &tio)

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let master_ = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        masterHandle = master_

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.terminationHandler = { [weak self] finished in
            self?.stateLock.lock()
            self?.isRunning = false
            self?.stateLock.unlock()
            onExit(finished.terminationStatus)
        }

        master_.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onOutput([UInt8](data))
        }

        do {
            try process.run()
        } catch {
            master_.readabilityHandler = nil
            throw PTYError.spawnFailed(String(describing: error))
        }
        isRunning = true
        // Parent doesn't need the slave side once the child holds it.
        try? slaveHandle.close()
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
        guard isRunning else { return }
        process.terminate()
    }

    public func forceKill() {
        guard isRunning else { return }
        #if canImport(Darwin)
            Darwin.kill(process.processIdentifier, SIGKILL)
        #elseif canImport(Glibc)
            Glibc.kill(process.processIdentifier, SIGKILL)
        #endif
    }
}
