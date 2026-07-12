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
  if vim.g.superlemon_default_keymaps == 0
    or vim.g.superlemon_default_keymaps == false
  then
    return
  end

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

return M
