-- superlemon.appearance — GUI-reported background application.
--
-- `:h 'background'`: "The TUI or other UI sets this on startup if it can
-- detect the background color." Superlemon is that UI. In the Auto
-- appearance mode it reports the macOS system appearance at bridge startup
-- and again whenever the system switches; the Light/Dark Settings modes
-- report a forced value. Requiring this module has no side effects.

local M = {}

--- Apply one GUI-reported background.
---
--- Auto reports (force falsy) respect an explicit user choice: when
--- 'background' was set by something other than a previous report — the
--- user's configuration or a manual :set — the report backs off and the
--- user's value stands. A forced report (Settings Light/Dark) always
--- applies; because it records itself as the last applied value, switching
--- Settings back to Auto resumes system-following cleanly.
---@param value string "dark" or "light"
---@param force boolean|nil
---@return boolean applied
function M.apply(value, force)
  if value ~= "dark" and value ~= "light" then
    return false
  end
  if not force then
    local info = vim.api.nvim_get_option_info2("background", {})
    if info.was_set
      and vim.o.background ~= vim.g.superlemon_applied_background
    then
      return false
    end
  end
  if vim.o.background ~= value then
    -- Changing 'background' reloads an adaptive colorscheme (:h
    -- 'background'), so the whole theme follows in one assignment.
    vim.o.background = value
  end
  vim.g.superlemon_applied_background = value
  return true
end

return M
