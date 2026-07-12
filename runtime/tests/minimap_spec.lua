-- minimap_spec.lua -- bounded native-minimap data provider protocol.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

vim.g.superlemon_native_minimap = 1
vim.g.superlemon_native_tabs = 0
vim.g.superlemon_native_statusbar = 0

local calls = H.stub_gui()
local bufnr = vim.api.nvim_get_current_buf()
local winid = vim.api.nvim_get_current_win()
vim.bo[bufnr].filetype = "minimap-test"
vim.bo[bufnr].tabstop = 3
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "local 😀tail",
  "plain extmark",
  "third line",
})

vim.cmd("syntax on")
vim.cmd("syntax clear")
vim.api.nvim_set_hl(0, "MiniKeyword", { fg = 0x123456, bold = true })
vim.cmd([[syntax match MiniKeyword /\<local\>/]])
vim.api.nvim_set_hl(0, "MiniExtmark", { fg = 0xABCDEF, italic = true })
local ext_ns = vim.api.nvim_create_namespace("superlemon-minimap-test")
vim.api.nvim_buf_set_extmark(bufnr, ext_ns, 1, 6, {
  end_col = 13,
  hl_group = "MiniExtmark",
  priority = 220,
})

require("superlemon").setup(17)
local minimap = require("superlemon.minimap")

local function payloads(kind)
  local result = {}
  for _, call in ipairs(calls.notify) do
    local payload = call.method == "superlemon.minimap" and call.args[1] or nil
    if payload and payload.kind == kind then
      result[#result + 1] = payload
    end
  end
  return result
end

local function contents(request_id)
  return vim.tbl_filter(function(payload)
    return payload.request_id == request_id
  end, payloads("content"))
end

local function wait_for_content(request_id)
  vim.wait(1500, function()
    local list = contents(request_id)
    return #list > 0 and list[#list].complete == true
  end)
  return contents(request_id)
end

-- Current-tab normal windows are described; floats are excluded.
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 8,
  height = 2,
  style = "minimal",
})
minimap.push_windows()
local windows = payloads("windows")
local latest_windows = windows[#windows].windows
local normal_entry
local saw_float = false
for _, entry in ipairs(latest_windows) do
  if entry.winid == winid then
    normal_entry = entry
  elseif entry.winid == float_win then
    saw_float = true
  end
end
H.ok(normal_entry ~= nil, "windows payload includes current normal window")
H.eq(normal_entry and normal_entry.bufnr, bufnr, "window payload includes buffer identity")
H.eq(normal_entry and normal_entry.filetype, "minimap-test", "window payload includes filetype")
H.eq(normal_entry and normal_entry.tabstop, 3, "window payload includes tabstop")
H.eq(normal_entry and normal_entry.changedtick, vim.api.nvim_buf_get_changedtick(bufnr),
  "window payload includes changedtick")
H.eq(normal_entry and normal_entry.line_count, 3, "window payload includes line count")
H.ok((normal_entry and normal_entry.highlight_generation or 0) > 0,
  "window payload includes highlight generation")
local initial_highlight_generation = normal_entry.highlight_generation
H.eq(saw_float, false, "windows payload excludes floating windows")
vim.api.nvim_win_close(float_win, true)

-- Content is cooperative, UTF-8-safe, byte-indexed, and style-resolved.
H.eq(minimap.request({
  request_id = "styled",
  winid = winid,
  bufnr = bufnr,
  firstline = 0,
  lastline = 2,
  max_columns = 7,
}), true, "valid content request accepted")
local styled = wait_for_content("styled")
H.ok(#styled > 0, "content notification arrives")
local payload = styled[#styled]
H.eq(payload.changedtick, vim.api.nvim_buf_get_changedtick(bufnr), "content carries changedtick")
H.eq(payload.line_count, 3, "content carries authoritative line count")
H.eq(payload.highlight_generation, initial_highlight_generation,
  "content carries matching highlight generation")
H.eq(payload.firstline, 0, "content range is zero-based")
H.eq(payload.lastline, 2, "content range is end-exclusive")
H.eq(payload.lines[1].text, "local 😀", "raw text truncates on a UTF-8 character boundary")
H.eq(payload.lines[1].truncated, true, "truncated line is marked")

local legacy_span
for _, span in ipairs(payload.lines[1].spans) do
  if span.source == "legacy" and span.start_col == 0 and span.end_col == 5 then
    legacy_span = span
  end
end
H.ok(legacy_span ~= nil, "legacy syntax produces byte-indexed span")
H.eq(legacy_span and legacy_span.style.fg, 0x123456, "legacy span resolves RGB foreground")
H.eq(legacy_span and legacy_span.style.bold, true, "legacy span resolves font style")

local extmark_span
for _, span in ipairs(payload.lines[2].spans) do
  if span.source == "extmark" then
    extmark_span = span
  end
end
H.ok(extmark_span ~= nil, "persistent extmark produces a span")
H.eq(extmark_span and extmark_span.priority, 220, "extmark priority preserved")
H.eq(extmark_span and extmark_span.style.fg, 0xABCDEF, "extmark RGB resolved")
H.eq(extmark_span and extmark_span.style.italic, true, "extmark font style resolved")

-- A newer request for one window cancels an older scheduled generation.
H.eq(minimap.request({
  request_id = "stale",
  winid = winid,
  bufnr = bufnr,
  firstline = 0,
  lastline = 3,
  max_columns = 80,
}), true, "first generation accepted")
H.eq(minimap.request({
  request_id = "fresh",
  winid = winid,
  bufnr = bufnr,
  firstline = 0,
  lastline = 1,
  max_columns = 80,
}), true, "replacement generation accepted")
wait_for_content("fresh")
vim.wait(100, function() return false end)
H.eq(#contents("stale"), 0, "stale scheduled request emits no content")
H.ok(#contents("fresh") > 0, "latest request emits content")

-- Invalid window/buffer identities are rejected synchronously.
local other_buf = vim.api.nvim_create_buf(false, true)
H.eq(minimap.request({
  request_id = "wrong-buffer",
  winid = winid,
  bufnr = other_buf,
  firstline = 0,
  lastline = 1,
  max_columns = 80,
}), false, "request rejects a buffer not displayed by the window")

-- Attached buffer callbacks publish precise line-range invalidations.
local invalidations_before = #payloads("invalidate")
vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "replacement", "inserted" })
vim.wait(1000, function()
  return #payloads("invalidate") > invalidations_before
end)
local invalidations = payloads("invalidate")
local invalidation = invalidations[#invalidations]
H.eq(invalidation.bufnr, bufnr, "invalidation carries buffer identity")
H.eq(invalidation.line_count, 4, "invalidation carries current line count")
H.eq(invalidation.highlight_generation, initial_highlight_generation,
  "invalidation carries current highlight generation")
H.eq(invalidation.firstline, 2, "invalidation carries first changed line")
H.eq(invalidation.lastline, 3, "invalidation carries old end-exclusive line")
H.eq(invalidation.new_lastline, 4, "invalidation carries new end-exclusive line")

-- Hard max_columns remains bounded even when the caller asks for much more.
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { string.rep("x", 400) })
H.eq(minimap.request({
  request_id = "bounded-columns",
  winid = winid,
  bufnr = bufnr,
  firstline = 0,
  lastline = 1,
  max_columns = 10000,
}), true, "oversized column request accepted with a hard cap")
local bounded = wait_for_content("bounded-columns")
H.eq(vim.fn.strchars(bounded[#bounded].lines[1].text), 256,
  "content text never exceeds hard character cap")
H.eq(bounded[#bounded].lines[1].truncated, true, "hard-capped text marked truncated")

-- Highlight-affecting events bump the epoch, invalidate visible buffers, and
-- repush topology so native caches never combine an old palette with new spans.
local windows_before_highlight = #payloads("windows")
local invalidations_before_highlight = #payloads("invalidate")
vim.api.nvim_exec_autocmds("ColorScheme", { modeline = false })
vim.wait(1000, function()
  return #payloads("windows") > windows_before_highlight
    and #payloads("invalidate") > invalidations_before_highlight
end)
local highlighted_windows = payloads("windows")
local highlighted_entry
for _, entry in ipairs(highlighted_windows[#highlighted_windows].windows) do
  if entry.winid == winid then
    highlighted_entry = entry
  end
end
H.ok(highlighted_entry.highlight_generation > initial_highlight_generation,
  "ColorScheme bumps topology highlight generation")
local highlight_invalidations = payloads("invalidate")
local highlight_invalidation = highlight_invalidations[#highlight_invalidations]
H.eq(highlight_invalidation.highlights, true, "ColorScheme emits highlight invalidation")
H.eq(highlight_invalidation.line_count, 4, "highlight invalidation carries line count")
H.eq(highlight_invalidation.highlight_generation, highlighted_entry.highlight_generation,
  "highlight invalidation and topology share one generation")

-- Disabled minimaps cancel requests and publish an empty topology snapshot.
require("superlemon.chrome").set("minimap", false)
local disabled_windows = payloads("windows")
H.eq(disabled_windows[#disabled_windows].windows, {}, "disabling minimap clears window topology")
H.eq(minimap.request({
  request_id = "disabled",
  winid = winid,
  bufnr = bufnr,
  firstline = 0,
  lastline = 1,
  max_columns = 80,
}), false, "disabled minimap rejects content work")

H.finish()
