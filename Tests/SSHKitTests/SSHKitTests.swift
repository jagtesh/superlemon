import Foundation
import Testing

@testable import SSHKit

@Suite("SSH config host parsing")
struct SSHConfigHostsTests {
    @Test("concrete aliases in order, patterns and negations skipped")
    func parsesAliases() {
        let config = """
            # comment
            Host work
              HostName work.example.com
            Host web1 web2 *.internal
            Host=eq-style
            HOST caps
            Host !banned ?maybe star*
            Host work
            """
        #expect(
            SSHConfigHosts.parse(config) == ["work", "web1", "web2", "eq-style", "caps"])
    }

    @Test("missing config yields no hosts")
    func missingConfig() {
        #expect(SSHConfigHosts.listAliases(configPath: "/nonexistent/ssh_config") == [])
    }

    @Test("quoted alias with embedded space parses as a single token")
    func quotedAliasWithSpace() {
        let config = """
            Host "my server" other
            """
        #expect(SSHConfigHosts.parse(config) == ["my server", "other"])
    }

    @Test("Include pulls in Host entries from another file, relative to baseDirectory")
    func includeDirectiveResolvesRelativePath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkit-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let includedPath = tempDir.appendingPathComponent("extra.conf")
        try "Host from-include\n".write(to: includedPath, atomically: true, encoding: .utf8)

        let mainConfig = """
            Host main-host
            Include extra.conf
            """
        #expect(
            SSHConfigHosts.parse(mainConfig, baseDirectory: tempDir.path)
                == ["main-host", "from-include"])
    }

    @Test("Include with a glob pattern pulls in multiple files, sorted")
    func includeDirectiveResolvesGlob() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkit-include-glob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "Host from-a\n".write(
            to: tempDir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "Host from-b\n".write(
            to: tempDir.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)

        let mainConfig = """
            Include *.conf
            """
        #expect(
            SSHConfigHosts.parse(mainConfig, baseDirectory: tempDir.path)
                == ["from-a", "from-b"])
    }

    @Test("listAliases follows Include directives relative to the config file's directory")
    func listAliasesFollowsInclude() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkit-listaliases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mainPath = tempDir.appendingPathComponent("config")
        let includedPath = tempDir.appendingPathComponent("included")
        try "Host from-include\n".write(to: includedPath, atomically: true, encoding: .utf8)
        try """
            Host main
            Include included
            """.write(to: mainPath, atomically: true, encoding: .utf8)

        #expect(
            SSHConfigHosts.listAliases(configPath: mainPath.path) == ["main", "from-include"])
    }

    @Test("circular Include does not infinite loop")
    func circularIncludeTerminates() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshkit-circular-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("config")
        try """
            Host self
            Include config
            """.write(to: path, atomically: true, encoding: .utf8)

        #expect(SSHConfigHosts.listAliases(configPath: path.path) == ["self"])
    }
}

@Suite("SSH command builder")
struct SSHCommandBuilderTests {
    let endpoint = SSHEndpoint(destination: "dev", port: 2222, extraArguments: ["-J", "jump"])

    @Test("master connection: tty, multiplexing, persist, ready marker")
    func masterConnection() {
        let args = SSHCommandBuilder.masterConnection(endpoint: endpoint, stateDirectory: "/s")
        #expect(args.first == "-tt")
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPath=/s/cm-%C"))
        // A bounded idle persist (not `yes`): the app-quit path
        // (SSHMaster.disconnectSynchronously via RemoteMasterRegistry)
        // still exits promptly; this is only the crash/kill-9 backstop.
        #expect(args.contains("ControlPersist=600"))
        #expect(args.contains("-p") && args.contains("2222"))
        #expect(args.contains("-J") && args.contains("jump"))
        #expect(args.last == "echo \(SSHCommandBuilder.readyMarker)")
        // Destination precedes the remote command.
        #expect(args.firstIndex(of: "dev")! < args.count - 1)
    }

    @Test("channel command reuses the master without re-auth")
    func channelCommand() {
        let args = SSHCommandBuilder.channelCommand(
            endpoint: endpoint, stateDirectory: "/s", remoteCommand: ["echo", "hi"])
        #expect(args.contains("ControlMaster=no"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ControlPath=/s/cm-%C"))
        // Single shell string, PATH bootstrap prepended.
        #expect(args.last!.hasSuffix("echo hi"))
        #expect(args.last!.hasPrefix("PATH="))
    }

    @Test("embedded nvim defaults to the deployed managed config, isolated")
    func embeddedNvim() {
        let args = SSHCommandBuilder.embeddedNvim(endpoint: endpoint, stateDirectory: "/s")
        let remote = args.last!
        #expect(remote.contains("exec env NVIM_APPNAME=superlemon nvim --embed"))
        #expect(remote.contains(#"-u "$HOME/.superlemon/runtime/config/init.lua""#))
        #expect(remote.contains("runtimepath:prepend([[$HOME/.superlemon/runtime]])"))
    }

    @Test("remote-user config launches bare nvim, runtime still prepended")
    func embeddedNvimRemoteUser() {
        let args = SSHCommandBuilder.embeddedNvim(
            endpoint: endpoint, stateDirectory: "/s", config: .remoteUser)
        let remote = args.last!
        #expect(remote.contains("exec nvim --embed"))
        #expect(!remote.contains("NVIM_APPNAME"))
        #expect(!remote.contains(" -u "))
        #expect(remote.contains("runtimepath:prepend([[$HOME/.superlemon/runtime]])"))
    }

    @Test("custom config routes through the deployed diagnostic loader")
    func embeddedNvimCustom() {
        let args = SSHCommandBuilder.embeddedNvim(
            endpoint: endpoint, stateDirectory: "/s",
            config: .customInit(remotePath: SSHCommandBuilder.remoteCustomInitPath))
        let remote = args.last!
        #expect(remote.contains(#"env SUPERLEMON_CUSTOM_INIT="$HOME/.superlemon/custom-init.lua""#))
        #expect(remote.contains(#"-u "$HOME/.superlemon/runtime/config/custom-init.lua""#))
        #expect(!remote.contains("NVIM_APPNAME"))
    }

    @Test("control operations name the destination")
    func controlOperation() {
        let args = SSHCommandBuilder.controlOperation(
            "exit", endpoint: endpoint, stateDirectory: "/s")
        #expect(args.contains("-O") && args.contains("exit"))
        #expect(args.last == "dev")
    }
}
