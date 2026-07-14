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

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "The editor session is not running."
        case .malformedReply(let what):
            "The editor returned an unreadable \(what) listing."
        }
    }
}

struct NvimWorkspaceFileSource: DirectoryLister, WorkspaceIndexSource {
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
