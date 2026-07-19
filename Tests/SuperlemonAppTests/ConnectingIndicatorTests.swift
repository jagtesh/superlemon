// The pre-session "Connecting to Neovim…" affordance: the editor surface
// paints an opaque background from its very first frame, and the label only
// appears when startup outlives the grace period (slow remote transports),
// hiding permanently on the first presented flush.

import Testing

@testable import EditorHostKit

@Suite struct ConnectingIndicatorStateTests {
    @Test func slowStartupShowsThenHidesOnFirstContent() {
        var state = ConnectingIndicatorState()
        #expect(!state.isVisible)
        let shown = state.noteGraceElapsed()
        #expect(shown)
        #expect(state.isVisible)
        let hidden = state.noteContentPresented()
        #expect(hidden)
        #expect(!state.isVisible)
    }

    @Test func fastStartupNeverShows() {
        var state = ConnectingIndicatorState()
        // Content beat the grace period: the late timer must not show it.
        let hidden = state.noteContentPresented()
        #expect(!hidden)
        let shown = state.noteGraceElapsed()
        #expect(!shown)
        #expect(!state.isVisible)
    }

    @Test func contentKeepsTheLabelHiddenForever() {
        var state = ConnectingIndicatorState()
        _ = state.noteGraceElapsed()
        _ = state.noteContentPresented()
        // A stray later grace event (e.g. a second window attachment)
        // must not resurrect the label once content has been shown.
        let shown = state.noteGraceElapsed()
        #expect(!shown)
        #expect(!state.isVisible)
    }
}
