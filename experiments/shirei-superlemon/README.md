# Superlemon Shirei proof of concept

This experiment tests a deliberately small cross-platform Superlemon shell on
top of [Shirei](https://github.com/hasenj/go-shirei). It is separate from the
production Swift/AppKit application.

The RPC/process layer uses the maintained
[`neovim/go-client`](https://github.com/neovim/go-client) package. Shirei owns
the cross-platform window and cell rendering; Neovim remains the editor.

The proof of concept:

- launches and supervises `nvim --embed`;
- keeps Neovim authoritative for the buffer, cursor, mode, mappings, and undo;
- attaches with `nvim_ui_attach` and renders Neovim's real line-grid screen,
  including its command line, prompts, status text, and cursor;
- preserves Neovim highlight attributes, including visual selections;
- follows Neovim's mode-specific block, vertical, and horizontal cursors;
- forwards committed text, navigation keys, and Ctrl/Cmd letter chords; and
- restarts Neovim with capped backoff if it exits unexpectedly.

It intentionally does not yet implement mouse input, multiple grids, native
tabs, the file browser, or other Superlemon
chrome. The purpose is to prove the shared process/input/UI loop on macOS,
Windows, X11, and Wayland before investing in a complete port.

## Run

Install Go 1.24.4 or newer and Neovim, then run:

```sh
cd experiments/shirei-superlemon
go run . path/to/file
```

Set `SUPERLEMON_NVIM` if `nvim` is not on `PATH`.

## Verify

```sh
go test ./...
go build ./...
```
