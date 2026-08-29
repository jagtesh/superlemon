import Foundation
import Testing

@testable import SSHKit

/// `RemoteMasterRegistry` refcounts a shared ControlMaster per destination
/// (Bug 3: two "Open Remote Folder" windows to the same host must not have
/// one window's close kill the other's session). The graceful `exit`
/// seam is injectable so these are pure counting tests, no real `ssh`.
@Suite("RemoteMasterRegistry refcounting")
struct RemoteMasterRegistryTests {
    private actor ExitLog {
        private(set) var destinations: [SSHMaster] = []
        func record(_ master: SSHMaster) { destinations.append(master) }
        var count: Int { destinations.count }
    }

    @Test("retain twice, release once: master is not exited")
    @MainActor
    func retainTwiceReleaseOnceKeepsMasterAlive() async {
        let log = ExitLog()
        let registry = RemoteMasterRegistry(
            exit: { master in await log.record(master) },
            exitSynchronously: { _, _ in })
        let master = SSHMaster(endpoint: SSHEndpoint(destination: "dev"))

        registry.retain("dev", master: master)
        registry.retain("dev", master: master)
        await registry.release("dev")

        #expect(await log.count == 0)
        #expect(registry.holderCount(for: "dev") == 1)
    }

    @Test("retain twice, release twice: master is exited exactly once")
    @MainActor
    func retainTwiceReleaseTwiceExitsOnce() async {
        let log = ExitLog()
        let registry = RemoteMasterRegistry(
            exit: { master in await log.record(master) },
            exitSynchronously: { _, _ in })
        let master = SSHMaster(endpoint: SSHEndpoint(destination: "dev"))

        registry.retain("dev", master: master)
        registry.retain("dev", master: master)
        await registry.release("dev")
        await registry.release("dev")

        #expect(await log.count == 1)
        #expect(registry.holderCount(for: "dev") == 0)
    }

    @Test("releasing an unregistered destination is a no-op")
    @MainActor
    func releaseWithoutRetainDoesNothing() async {
        let log = ExitLog()
        let registry = RemoteMasterRegistry(
            exit: { master in await log.record(master) },
            exitSynchronously: { _, _ in })

        await registry.release("never-registered")

        #expect(await log.count == 0)
    }

    @Test("independent destinations don't share a refcount")
    @MainActor
    func independentDestinationsDoNotInterfere() async {
        let log = ExitLog()
        let registry = RemoteMasterRegistry(
            exit: { master in await log.record(master) },
            exitSynchronously: { _, _ in })
        let devMaster = SSHMaster(endpoint: SSHEndpoint(destination: "dev"))
        let stagingMaster = SSHMaster(endpoint: SSHEndpoint(destination: "staging"))

        registry.retain("dev", master: devMaster)
        registry.retain("staging", master: stagingMaster)
        await registry.release("dev")

        #expect(await log.count == 1)
        #expect(registry.holderCount(for: "dev") == 0)
        #expect(registry.holderCount(for: "staging") == 1)
    }

    @Test("exitAllSynchronously exits every registered master and clears the registry")
    @MainActor
    func exitAllSynchronouslyExitsEveryMaster() {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        let log = Log()
        let registry = RemoteMasterRegistry(
            exit: { _ in },
            exitSynchronously: { _, _ in log.increment() })
        let devMaster = SSHMaster(endpoint: SSHEndpoint(destination: "dev"))
        let stagingMaster = SSHMaster(endpoint: SSHEndpoint(destination: "staging"))
        registry.retain("dev", master: devMaster)
        registry.retain("staging", master: stagingMaster)
        // A second window on "dev" -- exitAllSynchronously bypasses the
        // refcount entirely, so this doesn't take two releases to clear.
        registry.retain("dev", master: devMaster)

        registry.exitAllSynchronously()

        #expect(log.count == 2)
        #expect(registry.holderCount(for: "dev") == 0)
        #expect(registry.holderCount(for: "staging") == 0)
    }
}

/// `TerminationAggregate` is the plain, `AppKit`-free decision logic behind
/// AppDelegate's app-wide quit coordinator (Bug 2): every participant must
/// consent before termination is approved, and the first decline cancels
/// the whole thing.
@Suite("TerminationAggregate")
struct TerminationAggregateTests {
    @Test("zero participants approves immediately")
    func zeroParticipantsApprovesImmediately() {
        let aggregate = TerminationAggregate(participants: 0)
        #expect(aggregate.status == .approved)
    }

    @Test("all participants replying true approves")
    func allTrueApproves() {
        var aggregate = TerminationAggregate(participants: 3)
        #expect(aggregate.add(reply: true) == .waiting)
        #expect(aggregate.add(reply: true) == .waiting)
        #expect(aggregate.add(reply: true) == .approved)
    }

    @Test("a single decline cancels regardless of order")
    func aDeclineCancels() {
        var aggregate = TerminationAggregate(participants: 3)
        #expect(aggregate.add(reply: true) == .waiting)
        #expect(aggregate.add(reply: false) == .cancelled)
        #expect(aggregate.status == .cancelled)
    }

    @Test("replies after settling are ignored")
    func repliesAfterSettlingAreIgnored() {
        var aggregate = TerminationAggregate(participants: 1)
        #expect(aggregate.add(reply: false) == .cancelled)
        // A late reply (e.g. a stale continuation resuming after the
        // aggregate already cancelled) must not flip the verdict.
        #expect(aggregate.add(reply: true) == .cancelled)

        var approved = TerminationAggregate(participants: 1)
        #expect(approved.add(reply: true) == .approved)
        #expect(approved.add(reply: false) == .approved)
    }
}

/// `SSHMaster` process-lifecycle behavior, exercised against a fake `ssh`
/// binary (the same technique `PTYProcessTests` uses) so it doesn't depend
/// on a real remote host.
@Suite("SSHMaster process lifecycle")
struct SSHMasterTests {
    /// Logs every invocation's argv to `logPath`, then behaves just enough
    /// like ssh for this test: an `-O <op>` control invocation exits
    /// immediately, while the primary `-tt` auth invocation stays alive for
    /// a few seconds (like an authenticated interactive session would)
    /// before self-terminating, so a leftover process from a failed abort
    /// doesn't linger.
    private func makeFakeSSH(in directory: URL, logPath: String) throws -> String {
        let scriptPath = directory.appendingPathComponent("fake-ssh.sh").path
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath)"
            case "$*" in
              *-O*) exit 0 ;;
              *) sleep 5 ;;
            esac
            """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    /// Confirms the regression Bug 3/7 depend on: cancelling a connection
    /// attempt must never run a second `ssh` invocation to exit the master
    /// (`-O exit`) -- it only ever touches the local auth process.
    ///
    /// This intentionally does not assert that the process has *exited* by
    /// the time this returns: signal delivery to a pty-session-leader child
    /// is not reliably observable inside this test runner's process
    /// hierarchy (confirmed independently, outside `swift test`, that
    /// `PTYProcess.terminate()`'s `SIGTERM` correctly reaches and reaps an
    /// identical fake-ssh child — see the commit/PR notes). What matters
    /// for this bug and is fully verifiable here is the command surface:
    /// no `-O exit` (or anything else) is ever spawned by `abortAuth()`.
    @Test("abortAuth never runs a second ssh invocation (no -O exit)")
    func abortAuthNeverSendsControlExit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkit-abortauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logPath = tempDir.appendingPathComponent("invocations.log").path
        let fakeSSH = try makeFakeSSH(in: tempDir, logPath: logPath)

        let master = SSHMaster(
            endpoint: SSHEndpoint(destination: "test-host"),
            sshPath: fakeSSH,
            stateDirectory: tempDir.appendingPathComponent("state").path)

        try await master.connect(onOutput: { _ in }, onExit: { _ in })

        // Give the fake auth process a moment to actually be running
        // before asking it to abort.
        try await Task.sleep(nanoseconds: 300_000_000)
        await master.abortAuth()
        try await Task.sleep(nanoseconds: 300_000_000)

        let invocations = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let lines = invocations.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)  // only the initial -tt auth invocation
        #expect(!invocations.contains("-O"))
    }
}
