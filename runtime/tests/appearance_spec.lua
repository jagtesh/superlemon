-- appearance_spec.lua — GUI-reported background application (CONTRACT.md
-- "Appearance"): auto reports follow the system but never override an
-- explicit user 'background'; forced Settings reports always apply and
-- hand control back to auto cleanly.
local H = dofile(vim.fs.dirname(arg[0]) .. "/helpers.lua")
H.setup_rtp()

local appearance = require("superlemon.appearance")

H.eq(appearance.apply("bogus"), false, "invalid values are rejected")
H.eq(vim.g.superlemon_applied_background, nil, "rejection records nothing")

-- Pristine session ('background' untouched): auto reports apply.
H.eq(appearance.apply("light"), true, "auto report applies on a pristine session")
H.eq(vim.o.background, "light", "background follows the report")
H.eq(vim.g.superlemon_applied_background, "light", "report records itself")

H.eq(appearance.apply("dark"), true, "later auto reports keep applying")
H.eq(vim.o.background, "dark", "system switches follow")

-- The user takes over explicitly: auto reports must back off.
vim.cmd("set background=light")
H.eq(appearance.apply("dark"), false, "auto respects an explicit user choice")
H.eq(vim.o.background, "light", "user's background stands")

-- Settings Light/Dark are deliberate user intent: they always apply, and
-- because the forced value records itself, auto resumes control afterward.
H.eq(appearance.apply("dark", true), true, "forced report overrides")
H.eq(vim.o.background, "dark", "forced background applied")
H.eq(appearance.apply("light"), true, "auto resumes after a forced report")
H.eq(vim.o.background, "light", "auto report applies again")

H.finish()
