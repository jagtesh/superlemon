# Superlemon

<p align="center">
  <img src="assets/superlemon-icon.png" alt="Superlemon icon" width="160">
</p>

Superlemon grew out of a love for Sublime Text's speed and native feel, and for
Neovim's expressive editing model. It brings those ideas together without
adding a Vim-emulation layer: Neovim is the editor. It remains authoritative
for buffers, modes, mappings, plugins, highlighting, undo, and every final grid
frame.

Superlemon is the native macOS application built around that engine. It turns
Neovim state into AppKit windows, pixels, motion, menus, panels, and gestures—
about as far as a native Mac integration can go without forking Neovim itself.
The result includes smooth display-linked scrolling, a native file browser,
Quick Open, a minimap, a buffer tab bar, and a command/status bar integrated
into the main window, plus proper Mac keyboard and IME support.

This is still Neovim, not merely an editor with a Vim mode. Your mappings and
Neovim plugins continue to work through your configuration, while Superlemon
adds native Mac surfaces where they improve the experience.

![Superlemon in action](media/superlemon-demo.gif)

## Requirements

- macOS 14+
- Swift 6

Packaged builds include Neovim, so users do not need to install it separately.
Running the bare executable during development uses Neovim 0.12+ from the
login-shell `PATH`; set `SUPERLEMON_NVIM` to an explicit executable path when
needed.

## Run

Install the latest release with Homebrew:

```sh
brew install --cask jagtesh/tap/superlemon
```

Or build and run from source:

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

The managed configuration lives in `runtime/config/`. Personal overrides belong
in `~/.config/superlemon/init.vim`; because Neovim remains the editor, this file
can also load ordinary Neovim plugins and define mappings just like any other
Neovim configuration. You can instead choose your existing Neovim init from
**Superlemon → Settings…**.

Common development overrides are:

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

Every push and pull request also produces a packaged macOS application in
GitHub Actions. To create a versioned GitHub Release from a clean, up-to-date
`main` branch:

```sh
scripts/release.sh 0.2.0
```

The command updates the application version, creates and pushes the release
commit and `v0.2.0` tag, and starts the release workflow. GitHub Actions tests
the tagged source, uploads its packaged application as a workflow artifact,
and attaches that exact archive to the corresponding GitHub Release.
Once the release workflow completes, publish its checksum-pinned Homebrew cask:

```sh
scripts/publish-homebrew-cask.sh 0.2.0
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
