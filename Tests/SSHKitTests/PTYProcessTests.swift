import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@testable import SSHKit

/// Verifies PTYProcess gives the child a real controlling terminal
/// (setsid + TIOCSCTTY, the login_tty(3) dance) rather than just wiring
/// the pty slave to stdin/stdout/stderr. Without a controlling tty,
/// OpenSSH's read_passphrase() can't open /dev/tty and interactive auth
/// (host-key confirmation, passwords, key passphrases) fails outright.
@Suite("PTYProcess controlling terminal + lifecycle")
struct PTYProcessTests {
    private actor OutputCollector {
        private var bytes: [UInt8] = []

        func append(_ chunk: [UInt8]) {
            bytes.append(contentsOf: chunk)
        }

        var text: String {
            String(decoding: bytes, as: UTF8.self)
        }
    }

    @Test("child process has a controlling terminal it can open as /dev/tty")
    func childHasControllingTerminal() async throws {
        let pty = PTYProcess()
        let collector = OutputCollector()

        let exitStatus = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try pty.start(
                    executable: "/bin/sh",
                    arguments: ["-c", "tty && test -c /dev/tty && echo HAS_TTY"],
                    onOutput: { bytes in
                        Task { await collector.append(bytes) }
                    },
                    onExit: { status in
                        continuation.resume(returning: status)
                    })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // Give the async collector task a beat to catch the final chunk.
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(exitStatus == 0)
        let output = await collector.text
        #expect(output.contains("HAS_TTY"))
    }

    @Test("writes to the master reach the child's stdin")
    func writeReachesChildStdin() async throws {
        let pty = PTYProcess()
        let collector = OutputCollector()

        let exitStatus = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try pty.start(
                    executable: "/bin/sh",
                    arguments: ["-c", "read x; echo got:$x"],
                    onOutput: { bytes in
                        Task { await collector.append(bytes) }
                    },
                    onExit: { status in
                        continuation.resume(returning: status)
                    })
                try pty.write(Array("hello\n".utf8))
            } catch {
                continuation.resume(throwing: error)
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(exitStatus == 0)
        let output = await collector.text
        #expect(output.contains("got:hello"))
    }

    @Test("exit status propagates through onExit")
    func exitStatusPropagates() async throws {
        let pty = PTYProcess()

        let exitStatus = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try pty.start(
                    executable: "/bin/sh",
                    arguments: ["-c", "exit 3"],
                    onOutput: { _ in },
                    onExit: { status in
                        continuation.resume(returning: status)
                    })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        #expect(exitStatus == 3)
    }

    @Test("the child does not inherit unrelated open file descriptors")
    func doesNotLeakUnrelatedFileDescriptors() async throws {
        var pipeFDs: [Int32] = [-1, -1]
        let pipeResult = pipeFDs.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        #expect(pipeResult == 0)
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        let pty = PTYProcess()
        let collector = OutputCollector()

        _ = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try pty.start(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "test -e /dev/fd/\(readFD) && echo LEAKED || echo CLEAN",
                    ],
                    onOutput: { bytes in
                        Task { await collector.append(bytes) }
                    },
                    onExit: { status in
                        continuation.resume(returning: status)
                    })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let output = await collector.text
        #expect(output.contains("CLEAN"))
        #expect(!output.contains("LEAKED"))
    }
}
