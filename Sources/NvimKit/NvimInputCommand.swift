/// An input operation queued by the app before it crosses into the
/// `NvimSession` actor. Keeping repeat counts semantic until the queue drains
/// avoids spawning work per wheel line while preserving the RPC sequence.
package enum NvimInputCommand: Sendable, Equatable {
    /// Lua receives Neovim's zero-based UI `topline`, validates that the
    /// window still represents the expected buffer, then converts the line to
    /// the one-based value accepted by `winrestview()`. Neovim requires its
    /// cursor to remain in the rendered viewport: preserve it when visible,
    /// otherwise clamp it to the nearest viewport edge before restoring the
    /// exact requested top line.
    private static let viewportTargetLua = """
        local window, expected_buffer, topline, activate = ...
        if not vim.api.nvim_win_is_valid(window) then
          return false
        end
        if vim.api.nvim_win_get_buf(window) ~= expected_buffer then
          return false
        end
        if activate then
          vim.api.nvim_set_current_win(window)
        end
        return vim.api.nvim_win_call(window, function()
          if vim.api.nvim_get_current_buf() ~= expected_buffer then
            return false
          end
          local cursor = vim.api.nvim_win_get_cursor(window)
          local line_count = vim.api.nvim_buf_line_count(expected_buffer)
          local anchor = math.max(1, math.min(topline + 1, line_count))
          local function set_cursor(line)
            local text = vim.api.nvim_buf_get_lines(
              expected_buffer, line - 1, line, false)[1] or ""
            vim.api.nvim_win_set_cursor(
              window, { line, math.min(cursor[2], #text) })
          end

          -- Anchor the cursor before restoring the view. Calling
          -- winrestview() with an off-screen cursor is immediately clamped by
          -- Neovim, before `w0`/`w$` can describe the requested viewport.
          set_cursor(anchor)
          local view = { topline = topline + 1 }
          vim.fn.winrestview(view)
          local first_visible = vim.fn.line("w0")
          local last_visible = vim.fn.line("w$")
          local target = math.max(first_visible, math.min(cursor[1], last_visible))
          set_cursor(target)
          vim.fn.winrestview(view)
          return true
        end)
        """

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
    case resizeGrid(grid: Int, cols: Int, rows: Int)
    case viewportTarget(
        grid: Int,
        window: Int,
        buffer: Int,
        topline: Int,
        activate: Bool = false
    )
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

        case .resizeGrid(let grid, let cols, let rows):
            return [
                .init(
                    method: "nvim_ui_try_resize_grid",
                    params: [
                        .int(Int64(grid)), .int(Int64(cols)), .int(Int64(rows)),
                    ])
            ]

        case .viewportTarget(_, let window, let buffer, let topline, let activate):
            return [
                .init(
                    method: "nvim_exec_lua",
                    params: [
                        .string(Self.viewportTargetLua),
                        .array([
                            .int(Int64(window)),
                            .int(Int64(buffer)),
                            .int(Int64(max(0, topline))),
                            .bool(activate),
                        ]),
                    ])
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

        case let (
            .resizeGrid(gridA, _, _),
            .resizeGrid(gridB, cols, rows)
        ) where gridA == gridB:
            return .resizeGrid(grid: gridB, cols: cols, rows: rows)

        case let (
            .viewportTarget(_, windowA, _, _, activateA),
            .viewportTarget(grid, windowB, buffer, topline, activateB)
        ) where windowA == windowB && activateA == activateB:
            // Activation is part of the identity: a required activation must
            // never disappear into an adjacent passive viewport update.
            return .viewportTarget(
                grid: grid,
                window: windowB,
                buffer: buffer,
                topline: topline,
                activate: activateB)

        default:
            return nil
        }
    }
}
