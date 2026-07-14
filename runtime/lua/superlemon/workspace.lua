-- superlemon.workspace — project file listings served to the GUI over RPC
-- (CONTRACT.md "superlemon.workspace"). The GUI calls these when the
-- session's filesystem is not the GUI machine's (remote transports): vim.uv
-- here always enumerates the filesystem this nvim actually sees. Pure
-- request/response; requiring or calling this module has no side effects.

local M = {}

--- Immediate children of one directory for the native sidebar.
--- Symlinks are resolved one level so a link to a directory expands.
---@param path string absolute directory path
---@return { name:string, dir:boolean, hidden:boolean }[]
function M.list_dir(path)
  assert(type(path) == "string" and path ~= "", "workspace.list_dir: path required")
  local handle, err = vim.uv.fs_scandir(path)
  if not handle then
    error(err or ("could not read directory: " .. path), 0)
  end
  local entries = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "link" or kind == nil then
      local stat = vim.uv.fs_stat(vim.fs.joinpath(path, name))
      kind = stat and stat.type or kind
    end
    entries[#entries + 1] = {
      name = name,
      dir = kind == "directory",
      hidden = name:sub(1, 1) == ".",
    }
  end
  return entries
end

--- Root .gitignore subset shared with the GUI's local index (see
--- GitIgnoreRules in ShellKit and CONTRACT.md): blank/# lines skipped,
--- `!` negation with last-match-wins, trailing `/` directory-only rules,
--- patterns containing `/` anchored to the root-relative path, basename
--- match otherwise. glob2regpat supplies the fnmatch-style `*`/`?`/`[...]`
--- semantics (`*` may cross `/`, matching the GUI subset).
local function parse_gitignore(root)
  local rules = {}
  local file = io.open(vim.fs.joinpath(root, ".gitignore"), "r")
  if not file then
    return rules
  end
  for raw in file:lines() do
    local line = vim.trim(raw)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local negated = false
      if line:sub(1, 1) == "!" then
        negated = true
        line = line:sub(2)
      end
      local dir_only = false
      if line:sub(-1) == "/" then
        dir_only = true
        line = line:sub(1, -2)
      end
      local anchored = line:find("/", 1, true) ~= nil
      if line:sub(1, 1) == "/" then
        anchored = true
        line = line:sub(2)
      end
      if line ~= "" then
        local ok, regex = pcall(function()
          return vim.regex(vim.fn.glob2regpat(line))
        end)
        if ok and regex then
          rules[#rules + 1] = {
            regex = regex,
            negated = negated,
            dir_only = dir_only,
            anchored = anchored,
          }
        end
      end
    end
  end
  file:close()
  return rules
end

local function ignored(rules, rel, name, is_dir)
  local result = false
  for _, rule in ipairs(rules) do
    if is_dir or not rule.dir_only then
      local target = rule.anchored and rel or name
      if rule.regex:match_str(target) then
        result = not rule.negated
      end
    end
  end
  return result
end

--- Bounded synchronous walk for the GUI's Quick Open index. `.git` is
--- always pruned; an ignored directory is pruned whole (matching the GUI's
--- local walk, which never re-includes inside an excluded directory).
--- Stops after `max` files; `truncated` distinguishes exactly-max from
--- more-than-max. Runs on nvim's main loop, so the cap is also the latency
--- bound; the GUI refreshes sparingly (root changes and palette opens).
---@param root string absolute project root
---@param max integer file cap
---@return { files: { path:string, mtime:number }[], truncated: boolean }
function M.list_files(root, max)
  assert(type(root) == "string" and root ~= "", "workspace.list_files: root required")
  max = math.max(0, math.floor(tonumber(max) or 0))
  local rules = parse_gitignore(root)
  local files = {}
  local truncated = false
  local stack = { "" } -- root-relative directory paths; "" is the root
  while #stack > 0 and not truncated do
    local rel_dir = table.remove(stack)
    local abs_dir = rel_dir == "" and root or vim.fs.joinpath(root, rel_dir)
    local handle = vim.uv.fs_scandir(abs_dir)
    while handle do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local rel = rel_dir == "" and name or (rel_dir .. "/" .. name)
      if kind == nil then
        local stat = vim.uv.fs_stat(vim.fs.joinpath(root, rel))
        kind = stat and stat.type
      end
      if kind == "directory" then
        if name ~= ".git" and not ignored(rules, rel, name, true) then
          stack[#stack + 1] = rel
        end
      elseif kind == "file" then
        if not ignored(rules, rel, name, false) then
          if #files >= max then
            truncated = true
            break
          end
          local stat = vim.uv.fs_stat(vim.fs.joinpath(root, rel))
          files[#files + 1] = {
            path = rel,
            mtime = (stat and stat.mtime and stat.mtime.sec) or 0,
          }
        end
      end
      -- Symlinks and special files are not indexed, matching the GUI's
      -- local regular-files-only walk.
    end
  end
  return { files = files, truncated = truncated }
end

return M
