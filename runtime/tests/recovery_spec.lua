local H = dofile(vim.fs.dirname(arg[0]) .. '/helpers.lua')
H.setup_rtp()
local calls = H.stub_gui()
local recovery = require('superlemon.recovery')
local dir = H.tmpdir()
local path = dir .. '/note.txt'
vim.fn.writefile({'original'}, path)
vim.cmd.edit(path)
recovery.start(1)
local named = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'first', 'second'})
vim.cmd('vnew')
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'scratch'})
vim.cmd('tabnew')
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'other tab'})
vim.api.nvim_exec_autocmds('CursorMoved', {})
vim.wait(20, function() return false end)
local buffers, ws = {}, nil
for _, call in ipairs(calls.notify) do
  if call.method == 'superlemon.recovery' then
    local kind, data = unpack(call.args)
    if kind == 'buffer' then buffers[data.id] = vim.deepcopy(data)
    elseif kind == 'workspace' then ws = data
    elseif kind == 'lines' then
      local b = buffers[data.id]
      for _ = data.first + 1, data.last do table.remove(b.lines, data.first + 1) end
      for i, line in ipairs(data.lines) do table.insert(b.lines, data.first + i, line) end
      b.modified = true
    elseif kind == 'metadata' and buffers[data.id] then
      buffers[data.id].name, buffers[data.id].modified = data.name, data.modified
    elseif kind == 'remove' then buffers[data.id] = nil end
  end
end
H.eq(buffers[named].lines, {'first', 'second'}, 'mirror contains incremental edits')
H.eq(#ws.tabs, 2, 'workspace captures tabs')
vim.api.nvim_del_augroup_by_name('superlemon_recovery')
vim.cmd('tabonly!')
vim.cmd('only!')
vim.cmd('enew!')
-- Simulate a file being changed externally while the child is unavailable.
vim.fn.writefile({'external'}, path)
recovery.restore({buffers = vim.tbl_values(buffers), workspace = ws})
H.eq(#vim.api.nvim_list_tabpages(), 2, 'tabs restored')
H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {'other tab'}, 'active tab restored')
H.eq(vim.fn.readfile(path), {'external'}, 'restore never writes disk files')
H.eq(vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false), {'first', 'second'}, 'unsaved named text restored')
H.eq(vim.bo[vim.fn.bufnr(path)].modified, true, 'restored changes remain unsaved')
vim.cmd('tabfirst')
H.eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'split layout restored')
H.finish()
