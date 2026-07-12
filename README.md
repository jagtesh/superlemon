# Superlemon

Superlemon is a macOS-native code editor powered by an embedded Neovim
process. Neovim remains authoritative for buffers, modes, undo, mappings,
plugins, highlighting, windows, and final grid state. Superlemon supplies the
native Mac window, input bridge, renderer, file chrome, menus, panels, and
motion between Neovim's discrete frames.

The current editor includes:

- a Core Text/Core Graphics renderer composed from persistent row-sized
  `IOSurface` tiles;
- display-linked, interruptible smooth vertical scrolling with exact retained
  row history, cursor coupling, Reduce Motion support, and a bounded fast-scroll
  veil for gaps that cannot be represented exactly;
- a native file tree, fuzzy Quick Open, buffer tabs with Sublime-style preview
  behavior, and an evaluated native Neovim statusline;
- native command-line, completion, message, confirmation, file-open, folder-open,
  Save, and Save As surfaces;
- an `NSTextInputClient` bridge, including marked-text IME composition and a
  per-side Option/Meta policy;
- a Lua bridge for plugin-owned palettes, prompts, toasts, status segments, and
  sidebar decorations.

## Requirements

- macOS 14 or newer
- Swift 6 toolchain
- Neovim 0.12 or newer for the bundled managed configuration

Set `SUPERLEMON_NVIM` to an executable path when Neovim is not discoverable
through the login-shell `PATH` or `/opt/homebrew/bin/nvim`.

## Build and run

```sh
swift build
.build/debug/superlemon
```

The process working directory becomes the initial workspace root. A Finder
launch whose working directory is `/` starts in the user's home directory.

Useful development overrides:

| Variable | Purpose |
|---|---|
| `SUPERLEMON_NVIM` | Neovim executable path |
| `SUPERLEMON_RUNTIME` | bundled runtime directory |
| `SUPERLEMON_LISTEN` | expose the embedded Neovim on a server socket |
| `SUPERLEMON_SCROLL_TRACE=1` | enable the bounded in-memory scroll diagnostic ring |

## Configuration

The default launch uses [`runtime/config/init.lua`](runtime/config/init.lua),
which sources the annotated Superlemon baseline in
[`runtime/config/superlemon.vim`](runtime/config/superlemon.vim). Personal
Superlemon overrides belong in:

```text
$XDG_CONFIG_HOME/superlemon/init.vim
```

That is normally `~/.config/superlemon/init.vim`. It is sourced after the
bundled baseline, so personal values win. The same personal file is sourced
once before bridge setup when Superlemon launches with the user's own Neovim
configuration or an explicitly selected init file.

Open **Superlemon > Settings…** to choose the Neovim init source or create and
open the personal Superlemon file. Font name, font size, and line spacing stay
in Neovim's `guifont` and `linespace`; renderer and native-chrome settings live
in the annotated Superlemon file.

## Native file workflow

| Action | Shortcut | Behavior |
|---|---|---|
| Open File… | ⌘O | Native picker, then Neovim `:drop` |
| Open Folder… | ⇧⌘O | Changes Neovim's cwd and re-roots the sidebar, Quick Open, git state, and plugin decorations |
| Save | ⌘S | Sends the user-remappable `<D-s>` mapping; the bundled mapping writes named buffers and opens native Save As for unnamed buffers |
| Save As… | ⇧⌘S | Native picker, then Neovim `:saveas!` after AppKit confirms replacement |
| Quick Open… | ⌘P | Searches the current workspace index |

The GUI never writes buffer contents itself. Neovim performs every edit and
save so encodings, autocmds, undo, swap state, and modified flags remain
coherent.

## Tests

```sh
swift test
bash runtime/tests/run.sh
swift build -c release
SUPERLEMON_RUNTIME="$PWD/runtime" .build/release/superlemon --smoke
```

## Documentation map

- [`DESIGN.md`](DESIGN.md) — implemented architecture and authority boundaries
- [`NORTHSTAR.md`](NORTHSTAR.md) — aspirational product and experience direction
- [`runtime/CONTRACT.md`](runtime/CONTRACT.md) — fixed Swift/Lua RPC contract
- [`Sources/ChromeKit/WIRING.md`](Sources/ChromeKit/WIRING.md) — externalized
  Neovim UI wiring
- [`Sources/ShellKit/WIRING.md`](Sources/ShellKit/WIRING.md) — native workspace
  chrome wiring

the palette and geometry. `NORTHSTAR.md` turns that research into a destination;
the README, design document, and wiring contracts describe what ships today.
