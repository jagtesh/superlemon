-- minimap.lua -- bounded buffer/window data provider for native minimaps.
--
-- This module never creates Neovim windows or renders pixels. It reports the
-- visible normal-window topology, invalidates native caches from buffer attach
-- callbacks, and serves small cooperative content requests. The GUI remains
-- responsible for Core Text rasterization, clipping, motion, and interaction.

local M = {}

local api = vim.api
local uv = vim.uv

local MAX_REQUEST_LINES = 384
local CHUNK_LINES = 16
local MAX_COLUMNS = 256
local MAX_BASE_SPANS = 512
local MAX_EXTMARKS = 128
local MAX_EXTMARK_SPANS = 256
local WORK_SLICE_NS = 1500000 -- 1.5 ms on Neovim's main loop

local enabled = false
local attached = {}
local latest_by_window = {}
local request_serial = 0
local windows_timer
local highlight_generation = 0
local schedule_windows

local function active()
  return enabled and require("superlemon").active()
end

local function notify(payload)
  if not active() then
    return
  end
  vim.rpcnotify(vim.g.superlemon_channel, "superlemon.minimap", payload)
end

local function is_normal_window(winid)
  if not api.nvim_win_is_valid(winid) then
    return false
  end
  local ok, config = pcall(api.nvim_win_get_config, winid)
  return ok and config.relative == "" and not config.external
end

local function changedtick(bufnr)
  local ok, tick = pcall(api.nvim_buf_get_changedtick, bufnr)
  return ok and tick or -1
end

local function schedule_invalidate(payload)
  if not enabled then
    return
  end
  vim.schedule(function()
    notify(payload)
  end)
end

local function line_count(bufnr)
  local ok, count = pcall(api.nvim_buf_line_count, bufnr)
  return ok and count or 0
end

local function attach_buffer(bufnr)
  if attached[bufnr] or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local ok = api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, tick, firstline, lastline, new_lastline)
      schedule_invalidate({
        kind = "invalidate",
        bufnr = buf,
        changedtick = tick,
        line_count = line_count(buf),
        highlight_generation = highlight_generation,
        firstline = firstline,
        lastline = lastline,
        new_lastline = new_lastline,
      })
    end,
    on_reload = function(_, buf)
      schedule_invalidate({
        kind = "invalidate",
        bufnr = buf,
        changedtick = changedtick(buf),
        line_count = line_count(buf),
        highlight_generation = highlight_generation,
        firstline = 0,
        lastline = -1,
        new_lastline = -1,
        reload = true,
      })
      if schedule_windows then
        schedule_windows()
      end
    end,
    on_detach = function(_, buf)
      attached[buf] = nil
      schedule_invalidate({
        kind = "invalidate",
        bufnr = buf,
        changedtick = -1,
        line_count = 0,
        highlight_generation = highlight_generation,
        firstline = 0,
        lastline = -1,
        new_lastline = -1,
        detached = true,
      })
      if schedule_windows then
        schedule_windows()
      end
    end,
  })
  if ok then
    attached[bufnr] = true
  end
end

local function visible_windows()
  local windows = {}
  for _, winid in ipairs(api.nvim_tabpage_list_wins(0)) do
    if is_normal_window(winid) then
      local bufnr = api.nvim_win_get_buf(winid)
      attach_buffer(bufnr)
      windows[#windows + 1] = {
        winid = winid,
        bufnr = bufnr,
        buftype = vim.bo[bufnr].buftype,
        filetype = vim.bo[bufnr].filetype,
        tabstop = vim.bo[bufnr].tabstop,
        changedtick = changedtick(bufnr),
        line_count = line_count(bufnr),
        highlight_generation = highlight_generation,
      }
    end
  end
  return windows
end

--- Push all visible normal windows in the current tabpage.
function M.push_windows()
  if not active() then
    return
  end
  notify({ kind = "windows", windows = visible_windows() })
end

schedule_windows = function()
  if not active() then
    return
  end
  if not windows_timer then
    windows_timer = uv.new_timer()
  end
  windows_timer:stop()
  windows_timer:start(20, 0, vim.schedule_wrap(M.push_windows))
end

local function invalidate_highlights()
  highlight_generation = highlight_generation + 1
  request_serial = request_serial + 1
  latest_by_window = {}
  local generation = highlight_generation

  vim.schedule(function()
    if not active() or generation ~= highlight_generation then
      return
    end
    local seen = {}
    for _, winid in ipairs(api.nvim_tabpage_list_wins(0)) do
      if is_normal_window(winid) then
        local bufnr = api.nvim_win_get_buf(winid)
        if not seen[bufnr] then
          seen[bufnr] = true
          notify({
            kind = "invalidate",
            bufnr = bufnr,
            changedtick = changedtick(bufnr),
            line_count = line_count(bufnr),
            highlight_generation = generation,
            firstline = 0,
            lastline = -1,
            new_lastline = -1,
            highlights = true,
          })
        end
      end
    end
    M.push_windows()
  end)
end

--- Enable or disable all provider traffic. Turning off also invalidates every
--- outstanding request token; already-attached callbacks remain inert.
---@param on boolean
function M.set_enabled(on)
  on = on == true
  if enabled == on then
    if on then
      M.push_windows()
    end
    return
  end
  enabled = on
  latest_by_window = {}
  request_serial = request_serial + 1
  if on then
    M.push_windows()
  elseif require("superlemon").active() then
    vim.rpcnotify(vim.g.superlemon_channel, "superlemon.minimap", {
      kind = "windows",
      windows = {},
    })
  end
end

local function parse_winhighlight(winid)
  local result = {}
  for from, to in vim.wo[winid].winhighlight:gmatch("([^:,]+):([^,]+)") do
    result[from] = to
  end
  return result
end

local STYLE_KEYS = {
  "fg", "bg", "sp", "blend", "bold", "italic", "underline", "undercurl",
  "underdouble", "underdotted", "underdashed", "strikethrough", "reverse",
  "standout", "nocombine",
}

local function normalized_style(hl)
  local style = {}
  for _, key in ipairs(STYLE_KEYS) do
    if hl[key] ~= nil then
      style[key] = hl[key]
    end
  end
  return style
end

local function make_style_resolver(winid)
  local cache = {}
  local winhl = parse_winhighlight(winid)
  local ok, namespace = pcall(api.nvim_get_hl_ns, { winid = winid })
  if not ok then
    namespace = -1
  end

  return function(group)
    local cache_key = type(group) .. ":" .. tostring(group)
    if cache[cache_key] then
      return cache[cache_key]
    end

    local resolved_group = group
    if type(group) == "string" and namespace < 0 and winhl[group] then
      resolved_group = winhl[group]
    end

    local opts = { link = false, create = false }
    if type(resolved_group) == "number" then
      opts.id = resolved_group
    else
      opts.name = resolved_group
    end

    local hl = {}
    if namespace >= 0 then
      local ns_ok, ns_hl = pcall(api.nvim_get_hl, namespace, opts)
      if ns_ok and type(ns_hl) == "table" then
        hl = ns_hl
      end
    end
    if next(hl) == nil then
      local global_ok, global_hl = pcall(api.nvim_get_hl, 0, opts)
      if global_ok and type(global_hl) == "table" then
        hl = global_hl
      end
    end

    local style = normalized_style(hl)
    cache[cache_key] = style
    return style
  end
end

local function utf8_expected_length(lead)
  if lead < 0x80 then
    return 1
  elseif lead >= 0xC2 and lead <= 0xDF then
    return 2
  elseif lead >= 0xE0 and lead <= 0xEF then
    return 3
  elseif lead >= 0xF0 and lead <= 0xF4 then
    return 4
  end
  return 1
end

local function trim_incomplete_utf8(text)
  local length = #text
  if length == 0 then
    return text
  end
  local start = length
  while start > 1 do
    local byte = text:byte(start)
    if byte < 0x80 or byte >= 0xC0 then
      break
    end
    start = start - 1
  end
  local expected = utf8_expected_length(text:byte(start))
  if start + expected - 1 > length then
    return text:sub(1, start - 1)
  end
  return text
end

local function line_byte_length(bufnr, row, line_count)
  local start_offset = api.nvim_buf_get_offset(bufnr, row)
  local end_offset = api.nvim_buf_get_offset(bufnr, row + 1)
  local length = math.max(0, end_offset - start_offset)
  if row < line_count - 1 or vim.bo[bufnr].endofline then
    length = math.max(0, length - 1)
  end
  return length
end

local function read_line(bufnr, row, line_count, max_columns)
  local byte_length = line_byte_length(bufnr, row, line_count)
  local fetch_bytes = math.min(byte_length, max_columns * 4 + 4)
  local parts = api.nvim_buf_get_text(bufnr, row, 0, row, fetch_bytes, {})
  local prefix = trim_incomplete_utf8(parts[1] or "")
  local text = vim.fn.strcharpart(prefix, 0, max_columns)
  return {
    line = row,
    text = text,
    byte_length = byte_length,
    truncated = #text < byte_length,
    spans = {},
  }
end

local function add_span(by_line, row, start_col, end_col, source, priority, order, style)
  local entry = by_line[row]
  if not entry then
    return
  end
  local clipped_start = math.max(0, math.min(#entry.text, start_col))
  local clipped_end = math.max(clipped_start, math.min(#entry.text, end_col))
  if clipped_end <= clipped_start then
    return false
  end
  entry.spans[#entry.spans + 1] = {
    start_col = clipped_start,
    end_col = clipped_end,
    source = source,
    priority = priority,
    order = order,
    style = style,
  }
  return true
end

local function add_multiline_span(
  by_line, firstline, lastline, start_row, start_col, end_row, end_col,
  source, priority, order, style
)
  local added = 0
  local final_row = end_row
  if end_col == 0 then
    final_row = final_row - 1
  end
  local first_row = math.max(firstline, start_row)
  final_row = math.min(lastline - 1, final_row)
  for row = first_row, final_row do
    local entry = by_line[row]
    if entry then
      local from = row == start_row and start_col or 0
      local to = row == end_row and end_col or #entry.text
      if add_span(by_line, row, from, to, source, priority, order, style) then
        added = added + 1
      end
    end
  end
  return added
end

local function tree_sitter_spans(bufnr, firstline, lastline, by_line, resolve_style, deadline)
  local ts = vim.treesitter
  local highlighter = ts and ts.highlighter and ts.highlighter.active
    and ts.highlighter.active[bufnr]
  if not highlighter or type(highlighter.get_query) ~= "function"
    or not highlighter.tree or type(highlighter.tree.for_each_tree) ~= "function"
  then
    return nil, "unavailable"
  end

  if type(highlighter.tree.is_valid) == "function" then
    local valid_ok, valid = pcall(
      highlighter.tree.is_valid, highlighter.tree, false,
      { firstline, 0, lastline, 0 }
    )
    if valid_ok and not valid then
      return nil, "unavailable"
    end
  end

  local spans = 0
  local order = 0
  local exceeded = false
  local ok = pcall(function()
    highlighter.tree:for_each_tree(function(tree, language_tree)
      if exceeded or not tree then
        return
      end
      local root = tree:root()
      local root_start, _, root_end = root:range()
      if root_start >= lastline or root_end < firstline then
        return
      end

      local wrapper = highlighter:get_query(language_tree:lang())
      local query = wrapper and type(wrapper.query) == "function" and wrapper:query() or nil
      if not query then
        return
      end

      for capture, node, metadata in query:iter_captures(
        root, bufnr, firstline, lastline
      ) do
        if uv.hrtime() >= deadline or spans >= MAX_BASE_SPANS then
          exceeded = true
          return
        end
        local capture_name = query.captures[capture]
        if capture_name and capture_name:sub(1, 1) ~= "_" then
          local range = ts.get_range(node, bufnr, metadata and metadata[capture])
          local priority = tonumber(
            metadata and (metadata.priority
              or metadata[capture] and metadata[capture].priority)
          ) or (vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter) or 100
          local group = "@" .. capture_name .. "." .. language_tree:lang()
          order = order + 1
          spans = spans + add_multiline_span(
            by_line, firstline, lastline,
            range[1], range[2], range[4], range[5],
            "treesitter", priority, order, resolve_style(group)
          )
        end
      end
    end)
  end)

  if not ok or exceeded then
    for _, entry in pairs(by_line) do
      entry.spans = vim.tbl_filter(function(span)
        return span.source ~= "treesitter"
      end, entry.spans)
    end
    return nil, exceeded and "budget" or "unavailable"
  end
  return spans, nil
end

local function next_utf8_column(text, column)
  local lead = text:byte(column + 1)
  if not lead then
    return #text
  end
  return math.min(#text, column + utf8_expected_length(lead))
end

local function legacy_spans(winid, firstline, lastline, by_line, resolve_style, deadline)
  local spans = 0
  local order = 0
  local degraded = false

  local ok = pcall(api.nvim_win_call, winid, function()
    for row = firstline, lastline - 1 do
      local entry = by_line[row]
      local column = 0
      local run_start = 0
      local run_id
      while entry and column < #entry.text do
        if uv.hrtime() >= deadline or spans >= MAX_BASE_SPANS then
          degraded = true
          return
        end
        local next_column = next_utf8_column(entry.text, column)
        local id = vim.fn.synIDtrans(vim.fn.synID(row + 1, column + 1, 1))
        if run_id ~= nil and id ~= run_id then
          if run_id ~= 0 then
            local name = vim.fn.synIDattr(run_id, "name")
            order = order + 1
            spans = spans + 1
            add_span(
              by_line, row, run_start, column, "legacy", 50, order,
              resolve_style(name ~= "" and name or run_id)
            )
          end
          run_start = column
        end
        run_id = id
        column = next_column
      end
      if entry and run_id and run_id ~= 0 and column > run_start then
        local name = vim.fn.synIDattr(run_id, "name")
        order = order + 1
        spans = spans + 1
        add_span(
          by_line, row, run_start, column, "legacy", 50, order,
          resolve_style(name ~= "" and name or run_id)
        )
      end
    end
  end)

  return ok and spans or 0, degraded or not ok
end

local function extmark_spans(bufnr, firstline, lastline, by_line, resolve_style)
  local ok, marks = pcall(api.nvim_buf_get_extmarks, bufnr, -1,
    { firstline, 0 }, { lastline, 0 }, {
      details = true,
      overlap = true,
      type = "highlight",
      limit = MAX_EXTMARKS + 1,
      hl_name = true,
    })
  if not ok or #marks > MAX_EXTMARKS then
    return 0, not ok and "extmark-error" or "extmark-cap"
  end

  local order = 1000000
  local count = 0
  for _, mark in ipairs(marks) do
    local row, col, details = mark[2], mark[3], mark[4] or {}
    local end_row = details.end_row
    local end_col = details.end_col
    local groups = details.hl_group
    if end_row ~= nil and end_col ~= nil and groups ~= nil then
      if type(groups) ~= "table" then
        groups = { groups }
      end
      if #groups > 16 then
        for _, entry in pairs(by_line) do
          entry.spans = vim.tbl_filter(function(span)
            return span.source ~= "extmark"
          end, entry.spans)
        end
        return 0, "extmark-cap"
      end
      for stack_index, group in ipairs(groups) do
        if count >= MAX_EXTMARK_SPANS then
          for _, entry in pairs(by_line) do
            entry.spans = vim.tbl_filter(function(span)
              return span.source ~= "extmark"
            end, entry.spans)
          end
          return 0, "extmark-cap"
        end
        order = order + 1
        count = count + add_multiline_span(
          by_line, firstline, lastline, row, col, end_row, end_col,
          "extmark", tonumber(details.priority) or 0,
          order + stack_index, resolve_style(group)
        )
      end
    end
  end
  return count, nil
end

local function sort_spans(entries)
  for _, entry in ipairs(entries) do
    table.sort(entry.spans, function(a, b)
      if a.start_col ~= b.start_col then
        return a.start_col < b.start_col
      end
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      return a.order < b.order
    end)
  end
end

local function request_is_current(job)
  return enabled
    and latest_by_window[job.winid] == job.token
    and is_normal_window(job.winid)
    and api.nvim_win_get_buf(job.winid) == job.bufnr
    and api.nvim_buf_is_loaded(job.bufnr)
    and changedtick(job.bufnr) == job.changedtick
    and highlight_generation == job.highlight_generation
end

local function publish_chunk(job, firstline, lastline)
  local resolve_style = make_style_resolver(job.winid)
  local entries = {}
  local by_line = {}
  for row = firstline, lastline - 1 do
    local entry = read_line(job.bufnr, row, job.line_count, job.max_columns)
    entries[#entries + 1] = entry
    by_line[row] = entry
    if #entry.text > 0 then
      add_span(
        by_line, row, 0, #entry.text, "normal", 0, 0,
        resolve_style("Normal")
      )
    end
  end

  local base_source = "normal"
  local degraded
  local ts_count, ts_reason = tree_sitter_spans(
    job.bufnr, firstline, lastline, by_line, resolve_style,
    uv.hrtime() + WORK_SLICE_NS
  )
  if ts_count ~= nil then
    base_source = "treesitter"
  elseif ts_reason == "unavailable" then
    local legacy_count, legacy_degraded = legacy_spans(
      job.winid, firstline, lastline, by_line, resolve_style,
      uv.hrtime() + WORK_SLICE_NS
    )
    if legacy_count > 0 then
      base_source = "legacy"
    end
    if legacy_degraded then
      degraded = "legacy-budget"
    end
  elseif ts_reason == "budget" then
    degraded = "treesitter-budget"
  end

  local _, extmark_degraded = extmark_spans(
    job.bufnr, firstline, lastline, by_line, resolve_style
  )
  degraded = degraded or extmark_degraded
  sort_spans(entries)

  notify({
    kind = "content",
    request_id = job.request_id,
    winid = job.winid,
    bufnr = job.bufnr,
    changedtick = job.changedtick,
    line_count = job.line_count,
    highlight_generation = job.highlight_generation,
    firstline = firstline,
    lastline = lastline,
    complete = lastline >= job.lastline,
    clamped = job.clamped,
    highlight_source = base_source,
    degraded = degraded,
    lines = entries,
  })
end

local function run_job(job)
  if not request_is_current(job) then
    return
  end
  local firstline = job.nextline
  local lastline = math.min(job.lastline, firstline + CHUNK_LINES)
  publish_chunk(job, firstline, lastline)
  if not request_is_current(job) or lastline >= job.lastline then
    return
  end
  job.nextline = lastline
  vim.schedule(function()
    run_job(job)
  end)
end

--- Request a bounded zero-based, end-exclusive buffer range. The call merely
--- validates and schedules work; `kind=content` notifications carry results.
---@param opts table {request_id,winid,bufnr,firstline,lastline,max_columns}
---@return boolean accepted
function M.request(opts)
  if not active() or type(opts) ~= "table" then
    return false
  end
  local request_id = opts.request_id
  if type(request_id) ~= "number" and type(request_id) ~= "string" then
    return false
  end

  local function finite_number(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
      return nil
    end
    return number
  end

  local winid = finite_number(opts.winid)
  local bufnr = finite_number(opts.bufnr)
  local firstline = finite_number(opts.firstline)
  local requested_lastline = finite_number(opts.lastline)
  local max_columns = finite_number(opts.max_columns)
  if not winid or not bufnr or not firstline or not requested_lastline
    or not max_columns or firstline < 0 or requested_lastline < firstline
    or winid % 1 ~= 0 or bufnr % 1 ~= 0
    or not is_normal_window(winid) or not api.nvim_buf_is_loaded(bufnr)
    or api.nvim_win_get_buf(winid) ~= bufnr
  then
    return false
  end

  local line_count = api.nvim_buf_line_count(bufnr)
  firstline = math.min(line_count, math.floor(firstline))
  requested_lastline = math.min(line_count, math.floor(requested_lastline))
  max_columns = math.max(1, math.min(MAX_COLUMNS, math.floor(max_columns)))
  local lastline = math.min(requested_lastline, firstline + MAX_REQUEST_LINES)

  request_serial = request_serial + 1
  local token = request_serial
  latest_by_window[winid] = token
  attach_buffer(bufnr)

  local job = {
    token = token,
    request_id = request_id,
    winid = winid,
    bufnr = bufnr,
    changedtick = changedtick(bufnr),
    line_count = line_count,
    highlight_generation = highlight_generation,
    firstline = firstline,
    lastline = lastline,
    nextline = firstline,
    max_columns = max_columns,
    clamped = lastline < requested_lastline,
  }
  vim.schedule(function()
    if job.firstline == job.lastline and request_is_current(job) then
      notify({
        kind = "content",
        request_id = job.request_id,
        winid = job.winid,
        bufnr = job.bufnr,
        changedtick = job.changedtick,
        line_count = job.line_count,
        highlight_generation = job.highlight_generation,
        firstline = job.firstline,
        lastline = job.lastline,
        complete = true,
        clamped = job.clamped,
        highlight_source = "normal",
        lines = {},
      })
    else
      run_job(job)
    end
  end)
  return true
end

---@param group integer augroup shared by the runtime bridge
---@param initially_enabled boolean
function M.setup(group, initially_enabled)
  if windows_timer and not windows_timer:is_closing() then
    windows_timer:stop()
  end
  enabled = initially_enabled == true
  latest_by_window = {}
  request_serial = request_serial + 1
  highlight_generation = highlight_generation + 1

  api.nvim_create_autocmd(
    { "WinNew", "WinClosed", "WinEnter", "BufWinEnter", "BufWinLeave", "TabEnter" },
    { group = group, callback = schedule_windows }
  )
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "tabstop",
    callback = schedule_windows,
  })
  api.nvim_create_autocmd(
    { "ColorScheme", "Syntax", "FileType", "LspTokenUpdate", "DiagnosticChanged" },
    { group = group, callback = invalidate_highlights }
  )
  api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "winhighlight", "background", "termguicolors" },
    callback = invalidate_highlights,
  })

  M.push_windows()
end

return M
