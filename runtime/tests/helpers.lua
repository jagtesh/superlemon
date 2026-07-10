-- Minimal busted-free test helpers for `nvim --headless --clean -u NONE -l <spec>.lua`.
-- Specs load this via: local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")

local H = {}

H.failures = 0
H.passes = 0

local function out(line)
  io.stdout:write(line .. "\n")
  io.stdout:flush()
end

function H.ok(cond, name)
  if cond then
    H.passes = H.passes + 1
    out("PASS " .. name)
  else
    H.failures = H.failures + 1
    out("FAIL " .. name)
  end
end

function H.eq(got, want, name)
  if vim.deep_equal(got, want) then
    H.passes = H.passes + 1
    out("PASS " .. name)
  else
    H.failures = H.failures + 1
    out(("FAIL %s\n     want: %s\n     got:  %s"):format(name, vim.inspect(want), vim.inspect(got)))
  end
end

--- Absolute path to the runtime/ directory (parent of tests/).
function H.root()
  local script = (arg and arg[0]) or debug.getinfo(2, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(script) or script))
end

--- Prepend runtime/ to runtimepath so require("superlemon") resolves.
function H.setup_rtp()
  vim.opt.runtimepath:prepend(H.root())
end

--- Pretend a GUI is attached: stub nvim_list_uis and capture RPC traffic.
--- Must run BEFORE require("superlemon").setup().
---@return table calls { notify = {...}, request = {...}, request_result = any }
function H.stub_gui()
  local calls = { notify = {}, request = {}, request_result = nil }
  vim.api.nvim_list_uis = function()
    return { { chan = 1, width = 120, height = 40 } }
  end
  vim.rpcnotify = function(chan, method, ...)
    table.insert(calls.notify, { chan = chan, method = method, args = { ... } })
    return 1
  end
  vim.rpcrequest = function(chan, method, ...)
    table.insert(calls.request, { chan = chan, method = method, args = { ... } })
    return calls.request_result
  end
  return calls
end

--- Fresh temp dir (realpath-resolved so cwd/buffer-name comparisons match
--- on macOS where /tmp and /var are symlinks).
---@return string
function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir) or dir
end

--- Print summary and exit non-zero on any failure.
function H.finish()
  if H.failures == 0 then
    out(("OK — %d assertions passed"):format(H.passes))
    os.exit(0, true)
  else
    out(("%d FAILED, %d passed"):format(H.failures, H.passes))
    os.exit(1, true)
  end
end

return H
