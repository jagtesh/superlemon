import Foundation

/// Free (non-isolated) defaults for `RemoteMasterRegistry`'s injectable exit
/// seams — a closure *literal* written inline in the initializer below would
/// be inferred `@MainActor` (the enclosing type's isolation) and so would
/// not satisfy the plain, non-isolated function-type parameters.
public nonisolated func defaultExit(_ master: SSHMaster) async {
    await master.disconnect()
}
public nonisolated func defaultExitSynchronously(_ master: SSHMaster, _ timeout: TimeInterval) {
    master.disconnectSynchronously(timeout: timeout)
}

/// Multiple "Open Remote Folder" windows to the same destination share one
/// ControlMaster socket (`SSHCommandBuilder.controlPath` hashes only
/// host/port/user, and ssh's own `ControlMaster=auto` reuses it). Without
/// this registry, whichever window closed first ran `ssh -O exit` and took
/// every other window's mux channels — and their remote nvim sessions —
/// down with it. Refcounting per destination means the master only actually
/// exits once nothing is using it any more.
@MainActor
public final class RemoteMasterRegistry {
    private struct Entry {
        var master: SSHMaster
        var count: Int
    }

    private var entries: [String: Entry] = [:]

    /// Seam for tests: the graceful per-release exit, defaulting to the
    /// real `ssh -O exit` (`SSHMaster.disconnect()`).
    private let exit: (SSHMaster) async -> Void
    /// Seam for tests: the app-quit synchronous exit, defaulting to the
    /// real bounded `ssh -O exit` (`SSHMaster.disconnectSynchronously`).
    private let exitSynchronously: (SSHMaster, TimeInterval) -> Void

    public init(
        exit: @escaping (SSHMaster) async -> Void = defaultExit,
        exitSynchronously: @escaping (SSHMaster, TimeInterval) -> Void = defaultExitSynchronously
    ) {
        self.exit = exit
        self.exitSynchronously = exitSynchronously
    }

    /// One more window is now riding `destination`'s master. Safe to call
    /// for a destination that already has a live registered master (ssh's
    /// own `ControlMaster=auto` reuses the socket) — this just bumps the
    /// count; the caller's own connection attempt already succeeded by the
    /// time it retains.
    public func retain(_ destination: String, master: SSHMaster) {
        if var entry = entries[destination] {
            entry.count += 1
            entries[destination] = entry
        } else {
            entries[destination] = Entry(master: master, count: 1)
        }
    }

    /// One window is done with `destination`'s master. Only when the count
    /// reaches zero does this actually exit the master (`ssh -O exit`) —
    /// every earlier release just decrements, so sibling windows on the
    /// same host keep working.
    public func release(_ destination: String) async {
        guard var entry = entries[destination] else { return }
        entry.count -= 1
        if entry.count <= 0 {
            entries.removeValue(forKey: destination)
            await exit(entry.master)
        } else {
            entries[destination] = entry
        }
    }

    /// App-quit backstop: exit every still-registered master synchronously,
    /// bypassing the refcount entirely — the whole process is about to go
    /// away regardless of who still "holds" one, and this is the only
    /// chance to run `ssh -O exit` before `ControlPersist`'s idle timeout
    /// would otherwise be the sole cleanup.
    public func exitAllSynchronously(timeout: TimeInterval = 2) {
        let masters = entries.values.map(\.master)
        entries.removeAll()
        for master in masters {
            exitSynchronously(master, timeout)
        }
    }

    /// Test/debug seam: how many holders a destination currently has (0 if
    /// none registered).
    public func holderCount(for destination: String) -> Int {
        entries[destination]?.count ?? 0
    }
}
