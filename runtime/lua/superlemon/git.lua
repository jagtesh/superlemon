-- git.lua — slim git-status DATA PROVIDER (no UI). Subscribers — the
-- navbar's badge merge (navbar.lua), and any future consumer — register
-- via M.on_update; this module only gathers. Async via vim.system so a
-- slow repo never blocks nvim.

local M = {}

local DEBOUNCE_MS = 150
local timer
local generation = 0
local subscribers = {}

--- Register a subscriber called with the parsed `files` list on every
--- refresh (success or failure/not-a-repo, which reports `{}`). Used by
--- navbar.lua to merge git badges onto the tree; never unregistered —
--- setup() is called at most once per session.
---@param fn fun(files: table[])
function M.on_update(fn)
  subscribers[#subscribers + 1] = fn
end

local function publish(files)
  for _, fn in ipairs(subscribers) do
    local ok, err = pcall(fn, files)
    if not ok then
      vim.notify("superlemon.git subscriber error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Parse `git status --porcelain -z` output into { {path, status}, ... }.
--- Status is one letter: M(odified) A(dded) D(eleted) R(enamed) C(opied)
--- U(nmerged) ?(untracked) — the worktree column when set, else the index.
---@param out string
---@return table[]
function M.parse_porcelain(out)
  local files = {}
  local fields = vim.split(out, "\0", { plain = true, trimempty = true })
  local i = 1
  while i <= #fields do
    local entry = fields[i]
    local x, y = entry:sub(1, 1), entry:sub(2, 2)
    local path = entry:sub(4)
    local status
    if x == "?" then
      status = "?"
    elseif y ~= " " and y ~= "" then
      status = y
    else
      status = x
    end
    if x == "R" or x == "C" then
      i = i + 1 -- consume the rename/copy origin path field
    end
    if path ~= "" and status ~= " " and status ~= "" then
      files[#files + 1] = { path = path, status = status }
    end
    i = i + 1
  end
  return files
end

--- Run git and push the result. Overlapping refreshes are coalesced: only
--- the newest generation is allowed to push.
function M.refresh()
  if not require("superlemon").active() then
    return
  end
  generation = generation + 1
  local this = generation
  local cwd = vim.fn.getcwd()
  -- --no-optional-locks: a background observer must never take the index
  -- lock (it raced a real `git commit` during development).
  local ok = pcall(vim.system, { "git", "--no-optional-locks", "status", "--porcelain", "-z" }, {
    cwd = cwd,
    text = true,
  }, function(result)
    if this ~= generation then
      return -- superseded by a newer refresh
    end
    vim.schedule(function()
      -- Re-check: a newer refresh may have started between on_exit and this
      -- deferred callback — pushing now would emit stale (wrong-cwd) state.
      if this ~= generation or not require("superlemon").active() then
        return
      end
      local files = {}
      if result.code == 0 and result.stdout then
        files = M.parse_porcelain(result.stdout)
      end
      -- Not a repo / git missing → empty list: the GUI clears its badges.
      publish(files)
    end)
  end)
  if not ok then
    publish({})
  end
end

local function refresh_debounced()
  -- Invalidate an in-flight command immediately. DirChanged waits for the
  -- debounce before starting the next command; without this bump, an old
  -- cwd's result can land during that window and be applied to the new root.
  generation = generation + 1
  if not timer then
    timer = vim.uv.new_timer()
  end
  timer:stop()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(M.refresh))
end

function M.setup(group)
  vim.api.nvim_create_autocmd(
    { "BufWritePost", "FocusGained", "DirChanged", "VimResume" },
    { group = group, callback = refresh_debounced }
  )
  M.refresh()
end

return M
