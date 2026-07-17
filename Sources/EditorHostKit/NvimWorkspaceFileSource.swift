// NvimWorkspaceFileSource — sidebar and quick-open file data sourced
// through the nvim RPC channel (`require("superlemon.workspace")`, see
// runtime/CONTRACT.md) instead of the local filesystem. Used when the
// controller reports `hasRemoteFilesystem`: vim.uv on the far side of the
// transport always enumerates the filesystem that session actually sees.

import Foundation
import NvimKit
import ShellKit

enum NvimWorkspaceFileError: LocalizedError {
    case sessionUnavailable
    case malformedReply(String)
    case unreadableLocalFile(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "The editor session is not running."
        case .malformedReply(let what):
            "The editor returned an unreadable \(what) reply."
        case .unreadableLocalFile(let path):
            "Couldn’t read \(path)."
        }
    }
}

struct NvimWorkspaceFileSource: DirectoryLister, WorkspaceIndexSource, WorkspaceFileTransport {
    /// Resolves the live session at call time so one source instance
    /// survives session relaunches. The controller is captured weakly: the
    /// chrome that owns this source is itself owned by the same host view.
    private let sessionProvider: @MainActor @Sendable () -> NvimSession?

    @MainActor
    init(controller: NvimController) {
        sessionProvider = { [weak controller] in controller?.workspaceFileSession }
    }

    func list(_ url: URL) async throws -> [DirectoryEntry] {
        let reply = try await execLua(
            "return require('superlemon.workspace').list_dir(...)",
            args: [.string(url.path)],
            timeout: .seconds(15))
        guard let items = asArray(reply) else {
            throw NvimWorkspaceFileError.malformedReply("directory")
        }
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return DirectoryEntry(
                name: name,
                isDirectory: item["dir"]?.boolValue ?? false,
                isHidden: item["hidden"]?.boolValue)
        }
    }

    func listFiles(root: URL, maxFiles: Int) async throws -> WorkspaceIndexListing {
        // The far side walks natively; only one request crosses the
        // transport. Generous timeout: a cold cache on a large remote tree
        // is still one bounded (maxFiles-capped) walk.
        let reply = try await execLua(
            "return require('superlemon.workspace').list_files(...)",
            args: [.string(root.path), .int(Int64(maxFiles))],
            timeout: .seconds(60))
        guard let files = reply["files"].flatMap(asArray) else {
            throw NvimWorkspaceFileError.malformedReply("file-index")
        }
        let entries = files.compactMap { file -> WorkspaceIndexEntry? in
            guard let path = file["path"]?.stringValue else { return nil }
            return WorkspaceIndexEntry(
                path: path,
                mtime: Date(timeIntervalSince1970: file["mtime"]?.doubleValue ?? 0))
        }
        return WorkspaceIndexListing(
            entries: entries,
            isTruncated: reply["truncated"]?.boolValue ?? false)
    }

    // MARK: - WorkspaceFileTransport (drag & drop, CONTRACT.md)

    /// Raw bytes per RPC chunk. Chunks cross the wire base64-encoded
    /// (arbitrary bytes must not round-trip through msgpack STR/UTF-8), so
    /// each request carries ~700 KB — small enough to keep the remote
    /// event loop responsive and progress ticks flowing.
    private static let transferChunkBytes = 512 * 1024

    func stat(_ path: String) async throws -> WorkspaceTransferStat? {
        let reply = try await execLua(
            "return require('superlemon.workspace').stat(...)",
            args: [.string(path)],
            timeout: .seconds(15))
        guard let kind = reply["type"]?.stringValue else { return nil }  // vim.NIL: absent
        return WorkspaceTransferStat(
            isDirectory: kind == "directory",
            size: Int64(reply["size"]?.intValue ?? 0))
    }

    func createDirectory(_ path: String) async throws {
        _ = try await execLua(
            "return require('superlemon.workspace').mkdir(...)",
            args: [.string(path)],
            timeout: .seconds(15))
    }

    func move(_ source: String, to destination: String) async throws {
        _ = try await execLua(
            "return require('superlemon.workspace').rename(...)",
            args: [.string(source), .string(destination)],
            timeout: .seconds(15))
    }

    func writeFile(
        from local: URL, to path: String,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        guard let input = FileHandle(forReadingAtPath: local.path) else {
            throw NvimWorkspaceFileError.unreadableLocalFile(local.path)
        }
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let opened = try await execLua(
            "return require('superlemon.workspace').write_open(...)",
            args: [.string(path)],
            timeout: .seconds(15))
        guard let id = opened.intValue else {
            throw NvimWorkspaceFileError.malformedReply("write_open")
        }
        var committed = false
        defer {
            if !committed {
                // Fire-and-forget abort: frees the far side's handle and
                // unlinks the partial after a failure or cancellation.
                let abort = Value.array([.int(Int64(id)), .bool(false)])
                Task { [sessionProvider] in
                    guard let session = await sessionProvider() else { return }
                    _ = try? await session.request(
                        "nvim_exec_lua",
                        [.string("return require('superlemon.workspace').write_close(...)"),
                         abort],
                        timeout: .seconds(15))
                }
            }
        }

        var sent: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Self.transferChunkBytes),
                !data.isEmpty
            else { break }
            _ = try await execLua(
                "return require('superlemon.workspace').write_chunk(...)",
                args: [.int(Int64(id)), .string(data.base64EncodedString())],
                timeout: .seconds(30))
            sent += Int64(data.count)
            progress(sent, total)
        }
        _ = try await execLua(
            "return require('superlemon.workspace').write_close(...)",
            args: [.int(Int64(id)), .bool(true)],
            timeout: .seconds(15))
        committed = true
        progress(max(sent, total), total)
    }

    func readFile(
        _ path: String, to local: URL,
        progress: @escaping WorkspaceTransferProgressHandler
    ) async throws {
        let opened = try await execLua(
            "return require('superlemon.workspace').read_open(...)",
            args: [.string(path)],
            timeout: .seconds(15))
        guard let id = opened["id"]?.intValue else {
            throw NvimWorkspaceFileError.malformedReply("read_open")
        }
        let total = Int64(opened["size"]?.intValue ?? 0)
        defer {
            let free = Value.array([.int(Int64(id))])
            Task { [sessionProvider] in
                guard let session = await sessionProvider() else { return }
                _ = try? await session.request(
                    "nvim_exec_lua",
                    [.string("return require('superlemon.workspace').read_close(...)"), free],
                    timeout: .seconds(15))
            }
        }

        let partial = local.path + ".superlemon-partial-\(UUID().uuidString.prefix(8))"
        FileManager.default.createFile(atPath: partial, contents: nil)
        guard let output = FileHandle(forWritingAtPath: partial) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var committed = false
        defer {
            try? output.close()
            if !committed { try? FileManager.default.removeItem(atPath: partial) }
        }

        var received: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await execLua(
                "return require('superlemon.workspace').read_chunk(...)",
                args: [.int(Int64(id)), .int(Int64(Self.transferChunkBytes))],
                timeout: .seconds(30))
            guard let encoded = chunk.stringValue else { break }  // vim.NIL: EOF
            guard let data = Data(base64Encoded: encoded) else {
                throw NvimWorkspaceFileError.malformedReply("read_chunk")
            }
            try output.write(contentsOf: data)
            received += Int64(data.count)
            progress(received, total)
        }
        try output.close()
        guard rename(partial, local.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true
        progress(max(received, total), total)
    }

    /// nvim encodes an empty Lua table as an empty map; tolerate both.
    private func asArray(_ value: Value) -> [Value]? {
        value.arrayValue ?? (value.mapValue?.isEmpty == true ? [] : nil)
    }

    private func execLua(
        _ script: String, args: [Value], timeout: Duration
    ) async throws -> Value {
        guard let session = await sessionProvider() else {
            throw NvimWorkspaceFileError.sessionUnavailable
        }
        return try await session.request(
            "nvim_exec_lua", [.string(script), .array(args)], timeout: timeout)
    }
}
