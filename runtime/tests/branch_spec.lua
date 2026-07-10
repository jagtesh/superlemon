-- git branch parsing from .git/HEAD via vim.uv (no shelling out).
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local status = require("superlemon.status")
local base = H.tmpdir()

local function mkrepo(name, head_contents)
  local repo = base .. "/" .. name
  vim.fn.mkdir(repo .. "/.git", "p")
  vim.fn.writefile({ head_contents }, repo .. "/.git/HEAD")
  return repo
end

-- Normal repo on a branch.
local repo = mkrepo("repo", "ref: refs/heads/test-branch")
H.eq(status.git_branch(repo), "test-branch", "HEAD ref → branch name")

-- Lookup walks up from a subdirectory.
vim.fn.mkdir(repo .. "/deep/sub", "p")
H.eq(status.git_branch(repo .. "/deep/sub"), "test-branch", "walks up ancestors to find .git")

-- Detached HEAD → short sha.
local sha = "abc1234def5678900aabbccddeeff00112233445"
local det = mkrepo("detached", sha)
H.eq(status.git_branch(det), sha:sub(1, 7), "detached HEAD → 7-char short sha")

-- Worktree indirection: .git is a file pointing at the real gitdir.
local gitdir = base .. "/main-repo/.git/worktrees/wt1"
vim.fn.mkdir(gitdir, "p")
vim.fn.writefile({ "ref: refs/heads/wt-branch" }, gitdir .. "/HEAD")
local wt = base .. "/wt"
vim.fn.mkdir(wt, "p")
vim.fn.writefile({ "gitdir: " .. gitdir }, wt .. "/.git")
H.eq(status.git_branch(wt), "wt-branch", "gitdir-file indirection (worktree) resolves HEAD")

-- Not a repo → "".
local plain = base .. "/plain"
vim.fn.mkdir(plain, "p")
H.eq(status.git_branch(plain), "", 'not a repo → ""')

-- Nonsense input → "".
H.eq(status.git_branch(""), "", 'empty dir → ""')

-- Caching: branch_for caches per cwd until invalidated.
H.eq(status.branch_for(repo), "test-branch", "branch_for reads through cache")
vim.fn.writefile({ "ref: refs/heads/other-branch" }, repo .. "/.git/HEAD")
H.eq(status.branch_for(repo), "test-branch", "cached value survives HEAD change")
status.invalidate_branch_cache()
H.eq(status.branch_for(repo), "other-branch", "invalidate_branch_cache → fresh read")

H.finish()
