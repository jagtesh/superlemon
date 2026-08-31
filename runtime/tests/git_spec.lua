-- git_spec.lua — the slim git-status provider (subscriber plane; the
-- navbar merges the badges).
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

if vim.fn.executable("git") == 0 then
  print("SKIP — git not available")
  os.exit(0, true)
end

H.stub_gui()

local git = require("superlemon.git")
-- Observe through the subscriber plane, registered before setup() so the
-- initial refresh is captured too.
local updates = {}
git.on_update(function(files)
  updates[#updates + 1] = files
end)

-- A directory change must invalidate an old cwd's in-flight result
-- immediately, before the 150 ms debounce starts the replacement command.
local real_system = vim.system
local pending_callbacks = {}
vim.system = function(_, _, callback)
  pending_callbacks[#pending_callbacks + 1] = callback
  return {}
end
require("superlemon").setup(1)

local function git_push_count()
  return #updates
end

local pushes_before_dir_change = git_push_count()
vim.api.nvim_exec_autocmds("DirChanged", { modeline = false })
pending_callbacks[1]({ code = 0, stdout = "?? stale-from-old-root.txt\0" })
vim.wait(50)
H.eq(
  git_push_count(),
  pushes_before_dir_change,
  "DirChanged immediately suppresses an in-flight old-root result"
)
vim.system = real_system

-- Porcelain parsing (pure).
local parsed = git.parse_porcelain(table.concat({
  " M mod.txt",
  "A  added.txt",
  "?? new file.txt",
  "R  renamed.txt", -- followed by its origin-path field
  "old.txt",
  "D  gone.txt",
}, "\0") .. "\0")
local by_path = {}
for _, f in ipairs(parsed) do
  by_path[f.path] = f.status
end
H.eq(by_path["mod.txt"], "M", "worktree-modified parsed")
H.eq(by_path["added.txt"], "A", "index-added parsed")
H.eq(by_path["new file.txt"], "?", "untracked (with space) parsed")
H.eq(by_path["renamed.txt"], "R", "rename parsed")
H.eq(by_path["old.txt"], nil, "rename origin field consumed, not a file")
H.eq(by_path["gone.txt"], "D", "deletion parsed")

-- End to end against a real repository.
local dir = H.tmpdir()
vim.cmd("cd " .. dir)
local function sh(cmd)
  vim.fn.system("cd " .. vim.fn.shellescape(dir) .. " && " .. cmd)
end
sh("git init -q && git config user.email t@t && git config user.name t")
vim.fn.writefile({ "one" }, dir .. "/tracked.txt")
sh("git add tracked.txt && git commit -qm init")
vim.fn.writefile({ "one", "two" }, dir .. "/tracked.txt") -- modify
vim.fn.writefile({ "x" }, dir .. "/untracked.txt")

-- Wait for the update that reflects THIS repo (stale-generation pushes
-- from earlier cwds are suppressed by git.lua's double generation guard).
local function repo_push()
  for _, files in ipairs(updates) do
    for _, f in ipairs(files) do
      if f.path == "tracked.txt" then
        return files
      end
    end
  end
  return nil
end

git.refresh()
vim.wait(3000, function()
  return repo_push() ~= nil
end)

local files = repo_push()
H.ok(files ~= nil, "async refresh published this repo's status")
local got = {}
for _, f in ipairs(files or {}) do
  got[f.path] = f.status
end
H.eq(got["tracked.txt"], "M", "modified tracked file reported")
H.eq(got["untracked.txt"], "?", "untracked file reported")

H.finish()
