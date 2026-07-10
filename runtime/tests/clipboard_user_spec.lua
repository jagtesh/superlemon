-- User-configured g:clipboard must be respected (skip + single vim.notify).
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()
H.stub_gui()

local notices = {}
vim.notify = function(msg, level, opts)
  table.insert(notices, msg)
end

-- User config (loaded before us) already set a provider.
vim.g.clipboard = {
  name = "user-thing",
  copy = { ["+"] = { "true" }, ["*"] = { "true" } },
  paste = { ["+"] = { "true" }, ["*"] = { "true" } },
}

require("superlemon").setup(6)

H.eq(vim.g.clipboard.name, "user-thing", "user g:clipboard left untouched")
H.eq(require("superlemon.clipboard").active, false, "superlemon provider not activated")
H.eq(#notices, 1, "exactly one vim.notify about the skip")
H.ok(#notices >= 1 and notices[1]:find("clipboard") ~= nil, "notice mentions clipboard")

-- Re-setup must not warn again.
require("superlemon").setup(6)
H.eq(#notices, 1, "no duplicate warning on re-setup")
H.eq(vim.g.clipboard.name, "user-thing", "user provider still untouched after re-setup")

H.finish()
