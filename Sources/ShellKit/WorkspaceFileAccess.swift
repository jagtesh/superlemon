// WorkspaceFileAccess — how the native workspace chrome reads project file
// data: the sidebar's directory lister plus the quick-open index source,
// and whether those views describe THIS machine's filesystem.
//
// `.local` is the production default and the fast path (FileManager walks,
// FSEvents watching, FileOperations mutations). A session-backed access
// reads through the connected editor's RPC channel instead, so the tree and
// index reflect the filesystem that session actually sees — which need not
// be this machine's. Such a filesystem has no FSEvents equivalent, no
// Finder, and no local FileManager mutations; consumers gate those
// affordances on `isLocal`.

import Foundation

public struct WorkspaceFileAccess: Sendable {
    public let lister: any DirectoryLister
    public let indexSource: any WorkspaceIndexSource
    /// Streams drag-and-drop file transfers between this machine and the
    /// workspace filesystem (WorkspaceFileTransfer.swift).
    public let transport: any WorkspaceFileTransport
    /// True when `lister`/`indexSource`/`transport` read this machine's
    /// filesystem.
    public let isLocal: Bool

    public init(
        lister: any DirectoryLister,
        indexSource: any WorkspaceIndexSource,
        transport: any WorkspaceFileTransport,
        isLocal: Bool
    ) {
        self.lister = lister
        self.indexSource = indexSource
        self.transport = transport
        self.isLocal = isLocal
    }

    public static let local = WorkspaceFileAccess(
        lister: FileSystemLister(),
        indexSource: LocalWorkspaceIndexSource(),
        transport: LocalWorkspaceFileTransport(),
        isLocal: true)
}
