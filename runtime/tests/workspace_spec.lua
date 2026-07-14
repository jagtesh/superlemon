-- workspace_spec.lua — RPC-served file listings for the GUI's native
-- sidebar and Quick Open index (CONTRACT.md "superlemon.workspace").
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local workspace = require("superlemon.workspace")

-- Fixture tree in a fresh temp directory.
local root = vim.fs.joinpath(vim.uv.os_tmpdir(), "superlemon-workspace-" .. vim.uv.hrtime())
local function mkdir(rel)
  vim.fn.mkdir(rel == "" and root or vim.fs.joinpath(root, rel), "p")
end
local function touch(rel, contents)
  local path = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(contents or "x")
  f:close()
end

mkdir("")
mkdir("src/deep")
mkdir("docs")
mkdir(".git/objects")
mkdir("build")
mkdir("node_modules/pkg")
touch("main.swift")
touch(".hidden")
touch("src/app.js")
touch("src/deep/leaf.md")
touch("docs/readme.md")
touch(".git/config")
touch("build/out.o")
touch("node_modules/pkg/index.js")
touch("debug.log")
touch("keep.log")
touch("secret.txt")
touch("sub/secret.txt")
touch(".gitignore", table.concat({
  "# comment",
  "",
  "build/",
  "*.log",
  "!keep.log",
  "/secret.txt",
  "node_modules",
}, "\n"))

-- list_dir -----------------------------------------------------------------

local entries = workspace.list_dir(root)
local by_name = {}
for _, entry in ipairs(entries) do
  by_name[entry.name] = entry
end

H.ok(by_name["src"] and by_name["src"].dir == true, "list_dir marks directories")
H.ok(by_name["main.swift"] and by_name["main.swift"].dir == false, "list_dir marks files")
H.ok(by_name[".hidden"] and by_name[".hidden"].hidden == true, "list_dir flags dotfiles hidden")
H.ok(by_name[".git"] ~= nil, "list_dir reports everything; hiding is the GUI's policy")
H.ok(by_name["main.swift"].hidden == false, "regular names are not hidden")

-- One level only: no recursion artifacts.
H.ok(by_name["deep"] == nil and by_name["app.js"] == nil, "list_dir lists one level")

-- A symlink to a directory expands as a directory.
if vim.uv.fs_symlink(vim.fs.joinpath(root, "src"), vim.fs.joinpath(root, "link-to-src"), { dir = true }) then
  local linked
  for _, entry in ipairs(workspace.list_dir(root)) do
    if entry.name == "link-to-src" then
      linked = entry
    end
  end
  H.ok(linked ~= nil and linked.dir == true, "list_dir resolves a dir symlink one level")
  vim.uv.fs_unlink(vim.fs.joinpath(root, "link-to-src"))
end

local unreadable_ok = pcall(workspace.list_dir, vim.fs.joinpath(root, "no-such-dir"))
H.ok(not unreadable_ok, "list_dir raises for an unreadable directory")

-- list_files ---------------------------------------------------------------

local listing = workspace.list_files(root, 1000)
local paths = {}
for _, file in ipairs(listing.files) do
  paths[file.path] = file.mtime
end

H.ok(paths["main.swift"] ~= nil, "list_files indexes root files")
H.ok(paths["src/deep/leaf.md"] ~= nil, "list_files walks nested directories")
H.ok(paths[".gitignore"] ~= nil, "dotfiles are indexed (gitignore decides)")
H.ok(paths[".git/config"] == nil, ".git is always pruned")
H.ok(paths["build/out.o"] == nil, "directory-only rule prunes build/")
H.ok(paths["node_modules/pkg/index.js"] == nil, "basename dir rule prunes at depth")
H.ok(paths["debug.log"] == nil, "*.log is ignored")
H.ok(paths["keep.log"] ~= nil, "negation re-includes keep.log (last match wins)")
H.ok(paths["secret.txt"] == nil, "anchored /secret.txt is ignored at the root")
H.ok(paths["sub/secret.txt"] ~= nil, "anchored rule does not match at depth")
H.ok(type(paths["main.swift"]) == "number" and paths["main.swift"] > 0, "files carry epoch mtimes")
H.eq(listing.truncated, false, "under-cap walk is not truncated")

-- Truncation distinguishes exactly-max from more-than-max.
local total = #listing.files
local exact = workspace.list_files(root, total)
H.eq(#exact.files, total, "cap equal to the population keeps every file")
H.eq(exact.truncated, false, "exactly-max is not truncated")

local capped = workspace.list_files(root, total - 1)
H.eq(#capped.files, total - 1, "cap bounds the listing")
H.eq(capped.truncated, true, "more-than-max reports truncation")

vim.fn.delete(root, "rf")

H.finish()
