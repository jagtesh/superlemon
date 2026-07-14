// EditorSurface — the swift-cross-ui embedding of the superlemon editor:
// an NSViewRepresentable wrapping EditorHostKit's EditorHostNSView, for
// host apps (lemon-tmux) that render the editor as a swift-cross-ui view.
// macOS/AppKitBackend only.

import AppKit
import AppKitBackend
import EditorHostKit
import SwiftCrossUI

public struct EditorSurface: NSViewRepresentable {
    /// Persistent state for one realized surface: whether this representable
    /// owns the session lifecycle (it created the controller, or started an
    /// injected one) and must therefore stop it on dismantle.
    public final class Coordinator {
        var ownsSession = false
        public init() {}
    }

    /// The controller realized in `makeNSView`. Injected controllers let the
    /// host own session lifecycle (one nvim per pane); when nil, the surface
    /// creates its own. The controller identity is fixed for the lifetime of
    /// the realized view — pushing a different controller through an update
    /// is not supported; recreate the surface's view instead.
    private let controller: NvimController?
    /// Root for the sidebar, quick-open index, and file watcher.
    private let projectRoot: URL?
    /// Temporary native font-size override (the ⌘= zoom path); nil follows
    /// the guifont/linespace values from the active Neovim configuration.
    private let fontSize: CGFloat?
    /// When true (the default), `makeNSView` starts the nvim session; hosts
    /// that inject a controller they already started pass false. A session
    /// this surface neither created nor started is the host's to stop —
    /// dismantling the view leaves it running.
    private let startsSession: Bool

    public init(
        controller: NvimController? = nil,
        projectRoot: URL? = nil,
        fontSize: CGFloat? = nil,
        startsSession: Bool = true
    ) {
        self.controller = controller
        self.projectRoot = projectRoot
        self.fontSize = fontSize
        self.startsSession = startsSession
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> EditorHostNSView {
        let controller = controller ?? NvimController()
        context.coordinator.ownsSession = self.controller == nil || startsSession
        let view = EditorHostNSView(
            controller: controller,
            projectRoot: projectRoot ?? NvimController.workingDirectory())
        view.setFontSizeOverride(fontSize)
        if startsSession {
            Task { await controller.start() }
        }
        return view
    }

    public func updateNSView(_ nsView: EditorHostNSView, context: Context) {
        // Size is pushed by layout itself: setting the view's frame runs the
        // grid surface's layout pass, which coalesces an nvim_ui_try_resize.
        nsView.setFontSizeOverride(fontSize)
    }

    /// The protocol declares this requirement nonisolated; AppKit dismantles
    /// views on the main thread, so hop back onto the main actor to stop the
    /// nvim session (and its child process) with the view — but only when
    /// this surface owns the session (see Coordinator).
    nonisolated public static func dismantleNSView(_ nsView: EditorHostNSView, coordinator: Coordinator) {
        guard coordinator.ownsSession else { return }
        // assumeIsolated traps if AppKit ever dismantled off the main thread,
        // so handing the view across this boundary cannot actually race.
        nonisolated(unsafe) let view = nsView
        MainActor.assumeIsolated {
            view.controller.stop()
        }
    }
}
