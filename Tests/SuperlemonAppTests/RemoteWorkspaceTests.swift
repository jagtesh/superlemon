// End-to-end coverage for the remote-filesystem workspace path: a
// host-supplied transport (`nc -U` bridging stdio to an out-of-process
// `nvim --headless --listen` socket — the lemon-tmux MuxProbe pattern)
// drives NvimWorkspaceFileSource through the real superlemon.workspace
// runtime module. The "remote" filesystem is a local temp tree, but every
// listing crosses the RPC bridge exactly as it would over ssh.

import Foundation
import NvimKit
import Testing

@testable import EditorHostKit

private let remoteTestNvimPath =
    ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"] ?? "/opt/homebrew/bin/nvim"
private var remoteTestNvimAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: remoteTestNvimPath)
        && FileManager.default.isExecutableFile(atPath: "/usr/bin/nc")
}

@Suite("Remote workspace file source", .serialized)
struct RemoteWorkspaceTests {
    @Test(
        "sidebar and quick-open listings arrive through the socket bridge",
        .enabled(if: remoteTestNvimAvailable, "nvim not found at \(remoteTestNvimPath)"),
        .timeLimit(.minutes(1)))
    @MainActor
    func listsRemoteFilesystemThroughBridge() async throws {
        let fm = FileManager.default
        // Short base path: AF_UNIX socket paths cap at ~104 bytes.
        let scratch = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sl-remote-\(UInt32.random(in: 0..<UInt32.max))")
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(
            at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: project.appendingPathComponent("build"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try "x".write(
            to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "y".write(
            to: project.appendingPathComponent("src/app.js"), atomically: true, encoding: .utf8)
        try "o".write(
            to: project.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
        try "build/\n".write(
            to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        // The far side owns its runtimepath: the listening nvim, not the
        // bridge configuration, carries the superlemon runtime.
        let runtime = try #require(NvimController.runtimeDirectory())
        let socket = scratch.appendingPathComponent("nvim.sock").path
        let nvim = Process()
        nvim.executableURL = URL(fileURLWithPath: remoteTestNvimPath)
        nvim.arguments = [
            "--headless", "--listen", socket, "--clean", "-i", "NONE",
            "--cmd", "lua vim.opt.runtimepath:prepend([[\(runtime.path)]])",
        ]
        nvim.currentDirectoryURL = project
        try nvim.run()
        defer { nvim.terminate() }

        let deadline = ContinuousClock.now + .seconds(15)
        while !fm.fileExists(atPath: socket) {
            try #require(ContinuousClock.now < deadline, "listen socket never appeared")
            try await Task.sleep(for: .milliseconds(50))
        }

        let controller = NvimController(
            launchConfiguration: NvimLaunchConfiguration(
                binaryURL: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-U", socket]))
        #expect(controller.hasRemoteFilesystem)
        var startupFailure: String?
        controller.startupFailureHandler = { startupFailure = $0 }
        controller.exitHandler = { _, _ in }
        defer { controller.stop() }

        await controller.start()
        try #require(startupFailure == nil, Comment(rawValue: startupFailure ?? ""))
        try #require(controller.editorCommandsAvailable)

        let source = NvimWorkspaceFileSource(controller: controller)

        let entries = try await source.list(project)
        let names = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(names["src"]?.isDirectory == true)
        #expect(names["main.swift"]?.isDirectory == false)
        #expect(names[".gitignore"]?.isHidden == true)

        let listing = try await source.listFiles(root: project, maxFiles: 100)
        let paths = Set(listing.entries.map(\.path))
        #expect(paths.contains("main.swift"))
        #expect(paths.contains("src/app.js"))
        #expect(!paths.contains("build/out.o"), "remote walk honors the root .gitignore")
        #expect(!listing.isTruncated)
        let mainEntry = try #require(listing.entries.first { $0.path == "main.swift" })
        #expect(mainEntry.mtime > Date(timeIntervalSince1970: 0))

        // The capped walk reports truncation over the wire too.
        let capped = try await source.listFiles(root: project, maxFiles: 1)
        #expect(capped.entries.count == 1)
        #expect(capped.isTruncated)

        // A directory the remote side cannot read surfaces as a thrown
        // error (the sidebar's failure/retry placeholder), not a crash.
        await #expect(throws: (any Error).self) {
            _ = try await source.list(project.appendingPathComponent("missing"))
        }
    }
}
