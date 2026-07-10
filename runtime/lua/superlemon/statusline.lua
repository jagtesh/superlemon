-- statusline.lua — harvest the USER'S OWN statusline (powerline/lualine/
-- airline/hand-rolled, whatever &statusline evaluates to) WITHOUT rendering
-- it in the grid, via nvim_eval_statusline(..., {highlights = true}).
--
-- The GUI's native bar then displays the user's real statusline content as
-- styled native segments: full vimrc compatibility, no double bar. See
-- CONTRACT.md `superlemon.statusline`.

local M = {}

--- Resolve a highlight group to concrete colors/attrs, following links.
---@param group string
local function resolve_hl(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok then
    return {}
  end
  return hl
end

--- Evaluate the current window's statusline into styled segments.
---@return table[]|nil segments nil when no custom statusline is configured
function M.eval()
  local win = vim.api.nvim_get_current_win()
  local expr = vim.wo[win].statusline
  if expr == "" then
    expr = vim.o.statusline
  end
  if expr == "" then
    return nil -- stock statusline: the GUI falls back to its own chips
  end

  local ok, res = pcall(vim.api.nvim_eval_statusline, expr, {
    winid = win,
    highlights = true,
    maxwidth = 500,
  })
  if not ok or type(res) ~= "table" or type(res.str) ~= "string" then
    return nil
  end

  local segments = {}
  local hls = res.highlights or {}
  for i, h in ipairs(hls) do
    local stop = hls[i + 1] and hls[i + 1].start or #res.str
    local text = res.str:sub(h.start + 1, stop)
    if #text > 0 then
      local hl = resolve_hl(h.group)
      table.insert(segments, {
        text = text,
        fg = hl.fg,
        bg = hl.bg,
        bold = hl.bold or false,
        italic = hl.italic or false,
      })
    end
  end
  if #segments == 0 and res.str ~= "" then
    segments = { { text = res.str, bold = false, italic = false } }
  end
  return segments
end

--- Push the evaluated statusline to the GUI. Only meaningful while the
--- native bar is showing; rides the same debounce cadence as
--- superlemon.status (status.lua calls this from its push()).
function M.push()
  if not require("superlemon").active() then
    return
  end
  if not require("superlemon.chrome").state().native_statusbar then
    return
  end
  local segments = M.eval()
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.statusline", {
    segments = segments or vim.NIL,
  })
end

return M
