-- preview_spec.lua — VS Code/Sublime preview-buffer semantics (CONTRACT.md).
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local calls = H.stub_gui()
require("superlemon").setup(1)
vim.cmd("SuperlemonChrome tabs on")

local preview = require("superlemon.preview")

local dir = H.tmpdir()
vim.cmd("cd " .. dir)
for _, n in ipairs({ "one.txt", "two.txt", "three.txt" }) do
  vim.fn.writefile({ "content of " .. n }, dir .. "/" .. n)
end
local function path(n)
  return dir .. "/" .. n
end

local function last_buffers()
  local list = vim.tbl_filter(function(c)
    return c.method == "superlemon.buffers"
  end, calls.notify)
  return list[#list] and list[#list].args[1] or nil
end

-- Single-click: opens as the preview.
preview.open(path("one.txt"))
local one = vim.api.nvim_get_current_buf()
H.eq(preview.bufnr(), one, "single-click opens a preview buffer")
local entry
for _, b in ipairs(last_buffers().buffers) do
  if b.bufnr == one then
    entry = b
  end
end
H.eq(entry and entry.preview, true, "buffers payload flags the preview")

-- Clicking a second file REPLACES the clean preview (old tab disappears).
preview.open(path("two.txt"))
local two = vim.api.nvim_get_current_buf()
H.eq(preview.bufnr(), two, "new preview replaces the old one")
H.eq(vim.api.nvim_buf_is_valid(one), false, "clean old preview buffer is wiped")

-- Double-click promotes: the preview flag clears, buffer stays.
preview.promote(two)
H.eq(preview.bufnr(), nil, "promote clears the preview state")
for _, b in ipairs(last_buffers().buffers) do
  if b.bufnr == two then
    H.eq(b.preview, false, "promoted buffer no longer flagged")
  end
end

-- The promoted buffer is permanent: previewing a third file keeps it.
preview.open(path("three.txt"))
local three = vim.api.nvim_get_current_buf()
H.eq(vim.api.nvim_buf_is_valid(two), true, "promoted buffer survives new previews")
H.eq(preview.bufnr(), three, "third file is the new preview")

-- Clicking an already-open permanent file just switches; preview unchanged.
preview.open(path("two.txt"))
H.eq(vim.api.nvim_get_current_buf(), two, "existing permanent buffer: switch")
H.eq(preview.bufnr(), three, "preview state untouched by switching")

-- Editing a preview promotes it automatically...
vim.api.nvim_set_current_buf(three)
vim.api.nvim_buf_set_lines(three, 0, 0, false, { "edited" })
vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = three })
H.eq(preview.bufnr(), nil, "editing a preview promotes it")

-- ...so a modified would-be-replaced preview is never discarded.
preview.open(path("one.txt"))
H.eq(vim.api.nvim_buf_is_valid(three), true, "modified ex-preview survives")

-- open_permanent: opens pinned (double-click path).
local one2 = vim.api.nvim_get_current_buf()
H.eq(preview.bufnr(), one2, "one.txt re-opened as preview first")
preview.open_permanent(path("one.txt"))
H.eq(preview.bufnr(), nil, "open_permanent pins the previewed file")

H.finish()
