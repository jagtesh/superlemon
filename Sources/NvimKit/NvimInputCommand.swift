/// An input operation queued by the app before it crosses into the
/// `NvimSession` actor. Keeping repeat counts semantic until the queue drains
/// avoids spawning work per wheel line while preserving the RPC sequence.
package enum NvimInputCommand: Sendable, Equatable {
    case keys(String)
    case mouse(
        button: String,
        action: String,
        modifier: String,
        grid: Int,
        row: Int,
        col: Int,
        repeatCount: Int
    )
    case resize(cols: Int, rows: Int)
    case paste(String)

    package var notifications: [NvimSession.OutgoingNotification] {
        switch self {
        case .keys(let keys):
            return [
                .init(method: "nvim_input", params: [.string(keys)])
            ]

        case .mouse(
            let button, let action, let modifier, let grid, let row, let col, let repeatCount):
            guard repeatCount > 0 else { return [] }
            let notification = NvimSession.OutgoingNotification(
                method: "nvim_input_mouse",
                params: [
                    .string(button), .string(action), .string(modifier),
                    .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
                ],
                repeatCount: repeatCount)
            return [notification]

        case .resize(let cols, let rows):
            return [
                .init(
                    method: "nvim_ui_try_resize",
                    params: [.int(Int64(cols)), .int(Int64(rows))])
            ]

        case .paste:
            return []
        }
    }

    /// Fold only commands whose wire meaning is identical. This bounds the
    /// controller queue during momentum without changing notification order.
    package func coalesced(with newer: Self) -> Self? {
        switch (self, newer) {
        case let (
            .mouse(buttonA, actionA, modifierA, gridA, rowA, colA, countA),
            .mouse(buttonB, actionB, modifierB, gridB, rowB, colB, countB)
        ) where buttonA == buttonB && actionA == actionB && modifierA == modifierB
            && gridA == gridB && rowA == rowB && colA == colB:
            let (sum, overflow) = countA.addingReportingOverflow(countB)
            return .mouse(
                button: buttonA, action: actionA, modifier: modifierA,
                grid: gridA, row: rowA, col: colA,
                repeatCount: overflow ? Int.max : sum)

        case let (.resize(_, _), .resize(cols, rows)):
            // Only the newest adjacent size matters; no coordinate-bearing
            // input can sit between two commands that are adjacent here.
            return .resize(cols: cols, rows: rows)

        default:
            return nil
        }
    }
}
