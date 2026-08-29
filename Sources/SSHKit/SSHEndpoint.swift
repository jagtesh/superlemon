import Foundation

/// A destination reachable via the user's OpenSSH configuration. We
/// deliberately delegate auth, jump hosts, and host aliases to `ssh` itself —
/// anything that works in the user's terminal works here.
public struct SSHEndpoint: Sendable, Equatable {
    /// Host (or `Host` alias from ~/.ssh/config), optionally `user@host`.
    public var destination: String
    public var port: Int?
    /// Raw extra arguments appended verbatim (e.g. `-i`, `-J`).
    public var extraArguments: [String]

    public init(destination: String, port: Int? = nil, extraArguments: [String] = []) {
        self.destination = destination
        self.port = port
        self.extraArguments = extraArguments
    }
}

/// Pure command-line construction for the OpenSSH wrapper — kept side-effect
/// free so every invocation shape is unit-testable.
public enum SSHCommandBuilder {
    /// `ssh host cmd` runs a non-login shell, so Homebrew/user paths are
    /// often missing (macOS hosts notoriously lack /opt/homebrew/bin there).
    /// Prepend the usual suspects instead of requiring server-side config.
    static let remotePathBootstrap =
        #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin""#

    /// Printed by the master's remote command once auth has fully succeeded;
    /// its appearance in the pty stream is the "connected" signal.
    public static let readyMarker = "__SUPERLEMON_SSH_READY__"

    /// ControlPath lives in a short directory: unix sockaddr paths cap at
    /// ~104 bytes and `%C` hashing keeps the basename fixed-length.
    public static func controlPath(stateDirectory: String) -> String {
        "\(stateDirectory)/cm-%C"
    }

    /// The primary connection: authenticates interactively on a forced tty,
    /// prints the ready marker, and exits — `ControlPersist` keeps the
    /// authenticated master alive in the background for every later channel.
    /// A bounded 10-minute idle persist (not `yes`) is the backstop for
    /// process-level cleanup missing its chance to run `ssh -O exit` (a
    /// crash, `kill -9`, or any other exit that skips
    /// `applicationWillTerminate`) — see `SSHMaster.disconnectSynchronously`
    /// for the normal-quit path, which still exits promptly.
    public static func masterConnection(
        endpoint: SSHEndpoint, stateDirectory: String
    ) -> [String] {
        var args = [
            "-tt",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(stateDirectory: stateDirectory))",
            "-o", "ControlPersist=600",
        ]
        if let port = endpoint.port { args += ["-p", String(port)] }
        args += endpoint.extraArguments
        args += [endpoint.destination, "--", "echo \(readyMarker)"]
        return args
    }

    /// `ssh -O <op>` against an established master (check/exit).
    public static func controlOperation(
        _ operation: String, endpoint: SSHEndpoint, stateDirectory: String
    ) -> [String] {
        var args = [
            "-o", "ControlPath=\(controlPath(stateDirectory: stateDirectory))",
            "-O", operation,
        ]
        if let port = endpoint.port { args += ["-p", String(port)] }
        args.append(endpoint.destination)
        return args
    }

    /// A non-interactive command over the existing master (no re-auth).
    public static func channelCommand(
        endpoint: SSHEndpoint, stateDirectory: String, remoteCommand: [String]
    ) -> [String] {
        var args = [
            "-o", "ControlPath=\(controlPath(stateDirectory: stateDirectory))",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
        ]
        if let port = endpoint.port { args += ["-p", String(port)] }
        args += [endpoint.destination, "--"]
        args.append(remotePathBootstrap + " " + remoteCommand.joined(separator: " "))
        return args
    }

    /// Directory on the remote host holding the deployed superlemon runtime.
    /// Tilde on purpose: it's expanded by the remote shell, so it lands in
    /// the remote user's home regardless of what that path is.
    public static let remoteRuntimeDirectory = "~/.superlemon/runtime"

    /// Where a custom init file is deployed on the remote host. `$HOME`
    /// form so it survives both shell interpolation and env assignment.
    public static let remoteCustomInitPath = "$HOME/.superlemon/custom-init.lua"

    /// The editor channel: a remote `nvim --embed` whose stdio (over the
    /// authenticated master) IS the msgpack-RPC channel. The deployed
    /// superlemon runtime is prepended to the remote runtimepath, and
    /// `config` mirrors the local NvimConfigMode: managed and custom load
    /// the deployed init via `-u` (never the remote user's own init), while
    /// `.remoteUser` leaves the far side to own its config.
    public static func embeddedNvim(
        endpoint: SSHEndpoint, stateDirectory: String,
        config: RemoteNvimConfig = .editorManaged
    ) -> [String] {
        var remote = ["exec"]
        switch config {
        case .editorManaged:
            // NVIM_APPNAME keeps the remote user's plugins, shada, and swap
            // out of the managed session — same isolation as local managed.
            remote += ["env", "NVIM_APPNAME=superlemon"]
        case .customInit(let remotePath):
            remote += ["env", "SUPERLEMON_CUSTOM_INIT=\"\(remotePath)\""]
        case .remoteUser:
            break
        }
        remote += ["nvim", "--embed"]
        switch config {
        case .editorManaged:
            remote += ["-u", #""$HOME/.superlemon/runtime/config/init.lua""#]
        case .customInit:
            remote += ["-u", #""$HOME/.superlemon/runtime/config/custom-init.lua""#]
        case .remoteUser:
            break
        }
        remote += [
            // Double quotes: the remote shell expands $HOME before nvim
            // sees the lua literal.
            "--cmd",
            #""lua vim.opt.runtimepath:prepend([[$HOME/.superlemon/runtime]])""#,
        ]
        return channelCommand(
            endpoint: endpoint, stateDirectory: stateDirectory, remoteCommand: remote)
    }
}

/// Which Neovim configuration the remote embedded session loads, mirroring
/// the local `NvimConfigMode` (SSHKit stays independent of EditorHostKit).
public enum RemoteNvimConfig: Sendable, Equatable {
    /// Superlemon's managed config from the deployed runtime.
    case editorManaged
    /// The remote user's own init — bare nvim startup.
    case remoteUser
    /// A custom init file already deployed at `remotePath`, sourced through
    /// the runtime's diagnostic loader.
    case customInit(remotePath: String)
}
