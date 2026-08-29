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
        #expect(args.contains("ControlPersist=yes"))
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
