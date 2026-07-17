-- Superlemon's managed configuration.
--
-- Used when Settings selects Superlemon's managed configuration (the default):
-- nvim launches with `-u` pointing here, so the user's own Neovim init (and its
-- statusline / bufferline plugins) never loads. This is the fully-native
-- experience — Superlemon's chrome replaces the in-grid equivalents.
--
-- The actual configuration lives in `superlemon.managed` (which sources the
-- annotated sibling `superlemon.vim` and one optional personal override), so
-- bridge setup can apply the identical managed experience to host-supplied
-- transport sessions whose startup never ran this file. The launch plan's
-- pre-init `--cmd` has already prepended the bundled runtime to 'runtimepath',
-- making the module requirable here.

require("superlemon.managed").apply({
  safe_start = vim.env.SUPERLEMON_SAFE_START == "1",
})
