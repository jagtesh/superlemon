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

-- File transfer (CONTRACT.md "superlemon.workspace" — drag & drop) --------
--
-- Chunked, handle-based reads/writes so the GUI can stream files of any
-- size across the RPC channel with progress. Chunks travel as base64
-- (vim.base64, 0.10+): Lua strings are 8-bit clean, but arbitrary bytes
-- must not round-trip through the GUI's UTF-8 msgpack STR decoding.
-- Writes land in a ".superlemon-partial" sibling and rename over the
-- target only on commit, so a cancelled or failed transfer never leaves a
-- torn file. Handles are GUI-owned; a GUI that dies mid-transfer leaks the
-- handle until this nvim exits (bounded by the registry, never data loss).

local transfers = { next_id = 1, open = {} }

local function take_handle(id, kind)
  local handle = transfers.open[id]
  if not handle or handle.kind ~= kind then
    error("workspace: unknown " .. kind .. " transfer handle: " .. tostring(id), 0)
  end
  return handle
end

--- { type = "file"|"directory"|..., size = integer } or vim.NIL when absent.
function M.stat(path)
  assert(type(path) == "string" and path ~= "", "workspace.stat: path required")
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return vim.NIL
  end
  return { type = stat.type, size = stat.size }
end

--- mkdir -p; succeeds when the directory already exists.
function M.mkdir(path)
  assert(type(path) == "string" and path ~= "", "workspace.mkdir: path required")
  vim.fn.mkdir(path, "p")
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "directory" then
    error("could not create directory: " .. path, 0)
  end
  return true
end

--- Move/rename. Refuses to replace an existing destination: sidebar moves
--- are rearrangements, never silent overwrites.
function M.rename(from, to)
  assert(type(from) == "string" and from ~= "", "workspace.rename: from required")
  assert(type(to) == "string" and to ~= "", "workspace.rename: to required")
  if vim.uv.fs_stat(to) then
    error("destination already exists: " .. to, 0)
  end
  local ok, err = vim.uv.fs_rename(from, to)
  if not ok then
    error(err or ("could not move " .. from .. " to " .. to), 0)
  end
  return true
end

--- Opens a write transfer targeting `path`. Bytes accumulate in a partial
--- sibling; `write_close(id, true)` renames it over the target.
function M.write_open(path)
  assert(type(path) == "string" and path ~= "", "workspace.write_open: path required")
  local id = transfers.next_id
  transfers.next_id = transfers.next_id + 1
  local partial = path .. ".superlemon-partial-" .. id
  local fd, err = vim.uv.fs_open(partial, "w", 384) -- 0600
  if not fd then
    error(err or ("could not open for writing: " .. partial), 0)
  end
  transfers.open[id] = { kind = "write", fd = fd, path = path, partial = partial }
  return id
end

--- Appends one base64 chunk; returns total bytes written so far.
function M.write_chunk(id, b64)
  local handle = take_handle(id, "write")
  local data = vim.base64.decode(b64)
  local written, err = vim.uv.fs_write(handle.fd, data)
  if not written or written ~= #data then
    error(err or ("short write to " .. handle.partial), 0)
  end
  handle.written = (handle.written or 0) + written
  return handle.written
end

--- Commit renames the partial over the target (replacing it atomically);
--- abort unlinks the partial. Either way the handle is freed.
function M.write_close(id, commit)
  local handle = take_handle(id, "write")
  transfers.open[id] = nil
  vim.uv.fs_close(handle.fd)
  if not commit then
    vim.uv.fs_unlink(handle.partial)
    return true
  end
  local ok, err = vim.uv.fs_rename(handle.partial, handle.path)
  if not ok then
    vim.uv.fs_unlink(handle.partial)
    error(err or ("could not finalize " .. handle.path), 0)
  end
  return true
end

--- Opens a read transfer; returns { id, size }.
function M.read_open(path)
  assert(type(path) == "string" and path ~= "", "workspace.read_open: path required")
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    error("not a readable file: " .. path, 0)
  end
  local fd, err = vim.uv.fs_open(path, "r", 292) -- 0444
  if not fd then
    error(err or ("could not open for reading: " .. path), 0)
  end
  local id = transfers.next_id
  transfers.next_id = transfers.next_id + 1
  transfers.open[id] = { kind = "read", fd = fd, path = path, offset = 0 }
  return { id = id, size = stat.size }
end

--- Next base64 chunk of at most `max_bytes` raw bytes; vim.NIL at EOF.
function M.read_chunk(id, max_bytes)
  local handle = take_handle(id, "read")
  max_bytes = math.max(1, math.floor(tonumber(max_bytes) or 0))
  local data, err = vim.uv.fs_read(handle.fd, max_bytes, handle.offset)
  if data == nil then
    error(err or ("could not read " .. handle.path), 0)
  end
  if #data == 0 then
    return vim.NIL
  end
  handle.offset = handle.offset + #data
  return vim.base64.encode(data)
end

function M.read_close(id)
  local handle = take_handle(id, "read")
  transfers.open[id] = nil
  vim.uv.fs_close(handle.fd)
  return true
end

return M
