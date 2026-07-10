-- superlemon.status — pushes editor status to the GUI via
-- vim.rpcnotify(chan, "superlemon.status", payload). See CONTRACT.md.

local M = {}

local uv = vim.uv

local DEBOUNCE_MS = 100

-- git branch, cached per cwd; invalidated on DirChanged/FocusGained.
local branch_cache = {}

-- Single debounce timer shared by CursorMoved/CursorMovedI.
local timer

---------------------------------------------------------------------------
-- git branch (pure vim.uv fs — never shells out)
---------------------------------------------------------------------------

---@param path string
---@return string|nil file contents, nil if unreadable
local function read_file(path)
  local fd = uv.fs_open(path, "r", 292) -- 0444
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and stat.size > 0 and uv.fs_read(fd, stat.size, 0) or ""
  uv.fs_close(fd)
  return data
end

--- Resolve the HEAD file for `dir`, handling `.git` being either a
--- directory (normal repo) or a file with `gitdir: <path>` (worktrees,
--- submodules).
---@param dir string
---@return string|nil absolute path to HEAD, nil if `dir` has no .git
local function head_file(dir)
  local git = dir .. "/.git"
  local stat = uv.fs_stat(git)
  if not stat then
    return nil
  end
  if stat.type == "directory" then
    return git .. "/HEAD"
  end
  -- worktree / submodule indirection
  local body = read_file(git)
  local gitdir = body and body:match("^gitdir:%s*([^\r\n]+)")
  if not gitdir then
    return nil
  end
  gitdir = gitdir:gsub("%s+$", "")
  if not gitdir:match("^/") then
    gitdir = dir .. "/" .. gitdir
  end
  return gitdir .. "/HEAD"
end

--- Uncached branch lookup: walks up from `dir` looking for .git, then
--- parses HEAD. Returns "" when not in a repo; a short sha when detached.
---@param dir string
---@return string
function M.git_branch(dir)
  if type(dir) ~= "string" or dir == "" then
    return ""
  end
  local d = dir
  while true do
    local head_path = head_file(d)
    if head_path then
      local head = read_file(head_path)
      if not head or head == "" then
        return ""
      end
      head = head:gsub("%s+$", "")
      local branch = head:match("^ref:%s*refs/heads/(.+)$")
      if branch then
        return branch
      end
      local other_ref = head:match("^ref:%s*(.+)$")
      if other_ref then
        return other_ref
      end
      return head:sub(1, 7) -- detached HEAD: short sha
    end
    local parent = vim.fs.dirname(d)
    if not parent or parent == d then
      return ""
    end
    d = parent
  end
end

--- Cached branch for a cwd.
---@param cwd string
---@return string
function M.branch_for(cwd)
  local cached = branch_cache[cwd]
  if cached ~= nil then
    return cached
  end
  local branch = M.git_branch(cwd)
  branch_cache[cwd] = branch
  return branch
end

function M.invalidate_branch_cache()
  branch_cache = {}
end

---------------------------------------------------------------------------
-- status payload
---------------------------------------------------------------------------

---@return table payload per CONTRACT.md `superlemon.status`
function M.payload()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local cwd = uv.cwd() or vim.fn.getcwd()

  local file = ""
  if name ~= "" then
    file = vim.fs.relpath(cwd, name) or vim.fn.fnamemodify(name, ":.")
  end

  local pos = vim.api.nvim_win_get_cursor(0)

  return {
    mode = vim.api.nvim_get_mode().mode,
    file = file,
    modified = vim.bo[buf].modified,
    line = pos[1],
    col = pos[2] + 1, -- API col is 0-based; contract wants 1-based
    total_lines = vim.api.nvim_buf_line_count(buf),
    branch = M.branch_for(cwd),
    project = vim.fs.basename(cwd),
  }
end

--- Push a status notification to the GUI now. No-op when not attached.
function M.push()
  local chan = vim.g.superlemon_channel
  if chan == nil or #vim.api.nvim_list_uis() == 0 then
    return
  end
  vim.rpcnotify(chan, "superlemon.status", M.payload())
end

-- One shared timer; every cursor event restarts it, so a burst of motion
-- yields a single push ~100 ms after the last event.
local function push_debounced()
  if timer == nil or timer:is_closing() then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(M.push))
end

---------------------------------------------------------------------------
-- autocmds
---------------------------------------------------------------------------

---@param group integer augroup id (augroup `superlemon`, cleared by setup)
function M.setup(group)
  if timer and not timer:is_closing() then
    timer:stop()
  end

  vim.api.nvim_create_autocmd({ "ModeChanged", "BufEnter", "BufModifiedSet" }, {
    group = group,
    callback = function()
      M.push()
    end,
    desc = "superlemon: push status",
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      M.invalidate_branch_cache()
      M.push()
    end,
    desc = "superlemon: refresh branch + push status",
  })

  -- Contract: branch cache refreshed on FocusGained (the branch may have
  -- changed underneath us, e.g. `git switch` in a terminal). Push too so
  -- the GUI actually sees the fresh value.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      M.invalidate_branch_cache()
      M.push()
    end,
    desc = "superlemon: refresh branch on focus",
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = push_debounced,
    desc = "superlemon: push status (debounced)",
  })
end

return M
