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

  -- Wheel scrolling homes the cursor to column 0. Neovim keeps the cursor's
  -- remembered column (curswant) while scrolling, so it hops left/right as
  -- it lands on lines of different lengths. These mappings scroll and then
  -- move to column 0 with a plain `0` (not `^`), so the cursor stays put
  -- during a wheel scroll. The RHS re-plays the raw wheel key first — the
  -- mappings are non-recursive (vim.keymap.set defaults to noremap), so that
  -- inner key is the hardware scroll, not another pass through this mapping.
  -- Keyboard scrolling (<C-d>, `j`, `zz`, ...) never touches these keys, so
  -- it is unaffected. Independent of superlemon_default_keymaps above: this
  -- is a scroll behavior, not a Command-key shortcut, so it has its own
  -- opt-out.
  local scroll_homes_cursor_enabled = not (
    vim.g.superlemon_scroll_homes_cursor == 0
    or vim.g.superlemon_scroll_homes_cursor == false
  )

  if scroll_homes_cursor_enabled then
    local scroll_defaults = {
      { "n", "<ScrollWheelDown>", "<ScrollWheelDown>0" },
      { "x", "<ScrollWheelDown>", "<ScrollWheelDown>0" },
      { "i", "<ScrollWheelDown>", "<ScrollWheelDown><C-o>0" },
      { "n", "<ScrollWheelUp>", "<ScrollWheelUp>0" },
      { "x", "<ScrollWheelUp>", "<ScrollWheelUp>0" },
      { "i", "<ScrollWheelUp>", "<ScrollWheelUp><C-o>0" },
    }

    for _, spec in ipairs(scroll_defaults) do
      map(spec[1], spec[2], spec[3])
    end
  end
end

return M
