# Superlemon

<p align="center">
  <img src="assets/superlemon-icon.png" alt="Superlemon icon" width="160">
</p>

Superlemon is a native macOS code editor with Neovim at its core. Neovim owns
editing, buffers, mappings, plugins, highlighting, and undo; Superlemon adds a
fast AppKit interface with smooth scrolling, a file tree, buffer tabs, Quick
Open, a minimap, native command UI, and proper Mac keyboard and IME support.

![Superlemon in action](media/superlemon-demo.gif)

## Requirements

- macOS 14+
- Swift 6
- Neovim 0.12+

If Neovim is not on your login-shell `PATH`, set `SUPERLEMON_NVIM` to its full
path.

## Run

```sh
swift build
.build/debug/superlemon
```

Superlemon opens the current directory as its workspace. Press `⌘P` for Quick
Open, `⌘O` to open a file, and `⇧⌘O` to switch folders.

To build a native application bundle with the system-managed macOS icon:

```sh
scripts/package-app.sh
open dist/Superlemon.app
```

## Configure

The managed configuration lives in `runtime/config/`. Put personal overrides
in `~/.config/superlemon/init.vim`, or choose another Neovim init from
**Superlemon → Settings…**. Common development overrides are:

| Variable | Purpose |
| --- | --- |
| `SUPERLEMON_NVIM` | Path to the Neovim executable |
| `SUPERLEMON_RUNTIME` | Path to the bundled runtime |
| `SUPERLEMON_LISTEN` | Expose the embedded Neovim socket |

## Test

```sh
swift test
bash runtime/tests/run.sh
```

See [DESIGN.md](DESIGN.md) for the implemented architecture,
[NORTHSTAR.md](NORTHSTAR.md) for the product direction, and
[runtime/CONTRACT.md](runtime/CONTRACT.md) for the Swift/Lua interface.

## Contributing

Feedback and discussion are more valuable than unsolicited code. Tell us what
you like, what you do not, and what would make Superlemon better for you by
opening an issue. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before starting
a pull request.

## License

Copyright © 2026 Jagtesh Chadha. Released under the [BSD 3-Clause
License](LICENSE).
