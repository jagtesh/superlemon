-- superlemon.keymaps — DEFAULT <D-...> mappings per CONTRACT.md.
-- Every ⌘-chord arrives via nvim_input as <D-x>. User mappings (loaded
-- before setup()) always win: each default is guarded with
-- vim.fn.maparg(lhs, mode) == "".

local M = {}

--- Number of default mappings currently installed by us.
M.installed = 0

-- (mode .. " " .. lhs) keys for mappings we own, so re-running setup()
-- stays idempotent without treating our own maps as user maps.
local owned = {}

--- Notify the GUI to bump the font size. delta: 1 | -1 | 0 (0 = reset).
---@param delta integer
function M.font_bump(delta)
  local chan = vim.g.superlemon_channel
  if chan == nil then
    return
  end
  vim.rpcnotify(chan, "superlemon.font", { delta = delta })
end

--- Save through Neovim when the buffer is named; ask the GUI for its native
--- Save As sheet when it is not. This remains behind the default `<D-s>`
--- mapping, so a mapping supplied by the user still replaces the whole flow.
function M.save()
  if vim.api.nvim_buf_get_name(0) == "" then
    local chan = vim.g.superlemon_channel
    if chan ~= nil then
      vim.rpcnotify(chan, "superlemon.save_as")
    end
    return
  end
  vim.cmd.write()
end

---@param mode string
---@param lhs string
---@param rhs string|function
local function map(mode, lhs, rhs)
  local key = mode .. " " .. lhs
  if vim.fn.maparg(lhs, mode) ~= "" and not owned[key] then
    return -- user mapping wins
  end
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "superlemon default" })
  owned[key] = true
  M.installed = M.installed + 1
end

function M.setup()
  M.installed = 0

  -- The managed superlemon.vim documents every shortcut and exposes one
  -- master opt-out. A user config that does not define the variable retains
  -- the historical default: install only currently-unmapped Command chords.
  local default_keymaps_enabled = not (
    vim.g.superlemon_default_keymaps == 0
    or vim.g.superlemon_default_keymaps == false
  )

  if default_keymaps_enabled then
    local bump_up = function() M.font_bump(1) end
    local bump_down = function() M.font_bump(-1) end
    local bump_reset = function() M.font_bump(0) end

    local defaults = {
      -- <D-s> writes named buffers; unnamed buffers request native Save As.
      -- Lua callbacks, like <Cmd>, keep insert/visual state intact.
      { "n", "<D-s>", M.save },
      { "i", "<D-s>", M.save },
      { "x", "<D-s>", M.save },

      -- <D-a> select all
      { "n", "<D-a>", "ggVG" },
      { "i", "<D-a>", "<Esc>ggVG" },
      { "x", "<D-a>", "<Esc>ggVG" },

      -- <D-c> copy / <D-x> cut (visual)
      { "x", "<D-c>", '"+y' },
      { "x", "<D-x>", '"+d' },

      -- undo / redo
      { "n", "<D-z>", "u" },
      { "i", "<D-z>", "<Cmd>undo<CR>" },
      { "x", "<D-z>", "<Esc>u" },
      { "n", "<D-S-z>", "<C-r>" },
      { "i", "<D-S-z>", "<Cmd>redo<CR>" },

      -- new buffer
      { "n", "<D-n>", "<Cmd>enew<CR>" },
      { "i", "<D-n>", "<Cmd>enew<CR>" },

      -- font size → rpcnotify superlemon.font {delta=...}
      { "n", "<D-=>", bump_up },
      { "i", "<D-=>", bump_up },
      { "x", "<D-=>", bump_up },
      { "n", "<D-->", bump_down },
      { "i", "<D-->", bump_down },
      { "x", "<D-->", bump_down },
      { "n", "<D-0>", bump_reset },
      { "i", "<D-0>", bump_reset },
      { "x", "<D-0>", bump_reset },
    }

    for _, spec in ipairs(defaults) do
      map(spec[1], spec[2], spec[3])
    end
  end

  -- Wheel scrolling parks the cursor at column 0 only while it is actually
  -- being dragged by the gesture, and restores it afterwards. Neovim only
  -- moves the cursor's line during a wheel scroll when the scroll would
  -- otherwise push it out of the window; most wheel steps never touch it.
  -- When a step does drag the cursor, Neovim still applies the cursor's
  -- remembered column (curswant) to pick the landing column on the new
  -- line, so the column hops left/right as it lands on lines of different
  -- lengths — parking it at column 0 for the rest of the gesture keeps
  -- cursor-column-dependent plugins (matchparen, LSP document highlight,
  -- illuminate, ...) from repainting on every step. See wheel_step() and
  -- wheel_gesture_end() below. The RHS re-plays the raw wheel key first —
  -- the mappings are non-recursive (vim.keymap.set defaults to noremap), so
  -- that inner key is the hardware scroll, not another pass through this
  -- mapping — then calls wheel_step() via <Cmd>, which works in n/x/i
  -- without leaving the mode. Keyboard scrolling (<C-d>, `j`, `zz`, ...)
  -- never touches these keys, so it is unaffected. Independent of
  -- superlemon_default_keymaps above: this is a scroll behavior, not a
  -- Command-key shortcut, so it has its own opt-out.
  local scroll_homes_cursor_enabled = not (
    vim.g.superlemon_scroll_homes_cursor == 0
    or vim.g.superlemon_scroll_homes_cursor == false
  )

  if scroll_homes_cursor_enabled then
    local wheel_step = "<Cmd>lua require('superlemon.keymaps').wheel_step()<CR>"
    local scroll_defaults = {
      { "n", "<ScrollWheelDown>", "<ScrollWheelDown>" .. wheel_step },
      { "x", "<ScrollWheelDown>", "<ScrollWheelDown>" .. wheel_step },
      { "i", "<ScrollWheelDown>", "<ScrollWheelDown>" .. wheel_step },
      { "n", "<ScrollWheelUp>", "<ScrollWheelUp>" .. wheel_step },
      { "x", "<ScrollWheelUp>", "<ScrollWheelUp>" .. wheel_step },
      { "i", "<ScrollWheelUp>", "<ScrollWheelUp>" .. wheel_step },
    }

    for _, spec in ipairs(scroll_defaults) do
      map(spec[1], spec[2], spec[3])
    end
  end
end

-- Milliseconds of wheel-step idle time before a gesture is considered
-- finished and the cursor is restored to its remembered column. Must stay
-- below the app's ~120ms cursor-reveal delay (the app hides the cursor
-- while a wheel gesture is in motion and reveals it shortly after the last
-- step), so the cursor has already settled into its resting place by the
-- time it becomes visible again.
M.wheel_gesture_end_ms = 80

--- The in-flight wheel gesture, or nil between gestures.
--- { win, start_line, curswant, dragged, timer }
local gesture = nil

--- Test accessor: the in-flight gesture table, or nil.
function M._gesture()
  return gesture
end

local function close_gesture_timer(g)
  if g and g.timer then
    g.timer:stop()
    g.timer:close()
    g.timer = nil
  end
end

--- Ends the current wheel gesture, if any. When the gesture dragged the
--- cursor to a new line, restores the cursor to where Neovim's own vertical
--- motion would have left it: the remembered column (curswant) captured
--- when the gesture began, clamped to the dragged-to line's length by
--- vim.fn.cursor() itself (curswant == vim.v.maxcol, set by `$`, clamps to
--- end of line; insert mode allows one column past the last character).
--- curswant is restored too (not just the visible column), so subsequent
--- `j`/`k` behave as they would have without the scroll.
---
--- No-op if the gesture never dragged the cursor, if its window is gone, or
--- if the cursor is no longer at column 0 on that line — that means
--- something else (a click, an edit, a keystroke) moved the cursor during
--- the gesture, so we leave it alone rather than clobber that.
function M.wheel_gesture_end()
  local g = gesture
  gesture = nil
  if g == nil then
    return
  end
  close_gesture_timer(g)
  if not g.dragged then
    return
  end
  if not vim.api.nvim_win_is_valid(g.win) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(g.win)
  if cur[2] ~= 0 then
    return
  end
  vim.api.nvim_win_call(g.win, function()
    vim.fn.cursor({ cur[1], g.curswant, 0, g.curswant })
  end)
end

--- RHS of the default <ScrollWheelUp>/<ScrollWheelDown> mappings. Runs after
--- the raw wheel key it follows, so the cursor has already landed wherever
--- this step's native scroll took it. Starts a new gesture when none is in
--- flight (or the current window changed since the last step); homes the
--- column to 0 the first time a step actually drags the cursor to a new
--- line, leaving it alone on every other step (including later drags,
--- since the column is already 0 by then) so mid-gesture cursor moves are
--- as rare as possible. Every step restarts the idle timer that ends the
--- gesture and restores the remembered column (wheel_gesture_end).
function M.wheel_step()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line, col = cursor[1], cursor[2]

  if gesture ~= nil and gesture.win ~= win then
    -- Finish the other window's gesture now; its timer must not fire later
    -- against the gesture we are about to start.
    M.wheel_gesture_end()
  end
  if gesture == nil then
    gesture = {
      win = win,
      start_line = line,
      curswant = vim.fn.getcurpos()[5],
      dragged = false,
      timer = nil,
    }
  end

  if line ~= gesture.start_line and col > 0 then
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    gesture.dragged = true
  end

  close_gesture_timer(gesture)
  local timer = vim.uv.new_timer()
  gesture.timer = timer
  timer:start(M.wheel_gesture_end_ms, 0, vim.schedule_wrap(function()
    M.wheel_gesture_end()
  end))
end

return M
