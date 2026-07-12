
Visual/UX northstar for Superlemon, reverse-engineered from 8 screenshots of the
PNGs** (sRGB); values marked *≈* are estimated from antialiased regions. A developer
should be able to build the chrome from this document without the screenshots.

are @1x full-window captures (window ≈ 1790 × 1100 pt). `settings-*.png` and
`file-context-menu.png` are @2x crops (settings window ≈ 463 × 491 pt; measurements
below are already converted to points). `image-viewer.png` is @1x (window ≈ 1255 × 800 pt).

---

## 1. Overall visual identity


- **Flat, opaque, hairline-separated chrome.** No visible vibrancy/translucency in
  the titlebar, sidebar, or panels — solid fills with 1 px hairline borders. The
  only "material" surfaces are the quick-open palette, context menu, and the
  quick-open scrim.
- **Paper-white workspace in light mode.** Sidebar, editor, and preview are all
  `#FFFFFF`; only the titlebar block is gray. Structure comes from hairlines and
  the titlebar band, not from tinted panels.
- **Three-region layout:** file-tree sidebar (fixed ≈ 370 pt) · Neovim editor
  surface · right utility pane (Markdown preview / image viewer). Panels are
  edge-to-edge; zero gutters between regions.
- **A two-row header:** standard macOS titlebar (traffic lights, sidebar toggle,
  window title, trial pill) plus a slim tab/workspace strip beneath it.
- **A powerline-flavored native status bar:** colored mode badge and info chips
  with angled (slanted parallelogram) separators — Vim culture rendered natively.
- **Dark mode is not just inverted:** chrome goes neutral charcoal while the editor
  keeps its colorscheme background, chips flip from saturated-bg/white-text to
  pastel-bg/dark-text, and hairlines go pure black.

Window: standard macOS rounded corners (≈ 10 pt) and system window shadow.
Traffic lights in the normal position (≈ 20 pt inset, vertically centered in
titlebar row 1).

---

## 2. Master palette

### 2.1 Light mode (sampled)

| Token | Hex | Used for |
|---|---|---|
| `titlebar.bg` | `#F0F0EE` | titlebar + tab strip band |
| `titlebar.text` | ≈`#3A3A3A` / `#A2A3A5` | window title (dark) / tab-strip label (gray) |
| `surface.bg` | `#FFFFFF` | sidebar, editor, preview, status bar |
| `hairline` | `#DADADB` | pane dividers, panel borders |
| `sidebar.selection` | `#EAEAEA` | selected file row (full-width) |
| `editor.fg` | `#041420` | default editor text (near-black navy) |
| `editor.lineHighlight` | `#EEF0F1`–`#EFF1F3` | highlighted span/cursorline tint |
| `editor.lineNr` | ≈`#B0B6BC` | relative line numbers |
| `preview.codeBlock` | `#F6F8FA` | GitHub-light code block / status right cap |
| `preview.headerText` | `#8D8F91` | "Markdown Preview" pane header label |
| `status.modeBadge` | `#004DC8` | NORMAL mode badge bg (white text) |
| `status.chip` | `#E2E3E5` | file-name chip bg (dark text) |
| `status.lineCol` | `#005A37` | line:col chip bg (white text) |
| `palette.bg` | `#ECECEC` | quick-open panel |
| `palette.field` | `#FFFFFF` | quick-open search row |
| `palette.selection` | `#DBDBDB` | selected result row |
| `palette.secondary` | `#7D7E7F` | result path text |
| `palette.tertiary` | `#A9A9AA` | "32 files" count |
| `menu.bg` | `#E3E3E2` | context menu |
| `menu.text` | `#232323` | menu item labels |
| `viewer.canvas` | `#ECECEC` | image-viewer canvas + info bar |
| `overview.canvas` | `#E0E0DF` | workspace-overview background |
| `overview.card` | `#ECECEB` | card titlebar / "+" card |
| `scrim` | black @ ~30 % | quick-open dimming over content |

Syntax colors in the shots (markdown headings `#2F6BD5`*≈*, code-fence text
magenta, links blue underlined) come from the **Neovim colorscheme**, not chrome —
do not hard-code them.

### 2.2 Dark mode (sampled)

| Token | Hex | Used for |
|---|---|---|
| `titlebar.bg` | `#373736` | titlebar + tab strip band |
| `titlebar.text` | `#CDD2D7` | tab-strip label |
| `chrome.bg` | `#1E1E1E` | sidebar, status bar, preview header |
| `editor.bg` | `#1B2023` | editor surface (colorscheme-driven) |
| `editor.fg` | `#C7CDD1` | default editor text |
| `editor.lineHighlight` | `#2D3035` | highlighted line |
| `sidebar.selection` | `#343434` | selected file row |
| `hairline` | `#000000` | pane dividers (pure black) |
| `preview.bg` | `#0D1117` | GitHub-dark rendered markdown |
| `preview.codeBlock` | `#1C2129` | code blocks |
| `status.chip` | `#2F3336` | file-name chip bg (light text) |
| `status.modeBadge` | ≈`#66788A` | NORMAL badge (desaturated slate, dark text) |
| `status.lineCol` | `#ADC694` | line:col chip (sage green bg, **dark** text) |
| `status.project` | ≈`#C79595` | project chip accent (dusty rose) |
| `trial.pill` | `#3A3B38` | trial badge bg |

### 2.3 Settings window (dark, sampled)

| Token | Hex |
|---|---|
| toolbar/titlebar bg | `#3A3837` |
| body bg | `#2B2A28` |
| selected toolbar tile | `#474544` (rounded ≈ 6 pt) |
| accent (selected icon+label) | `#1186FF` (system blue) |
| inactive toolbar icon/label | `#9B9B9A` |
| text field / segmented track | `#363533` |
| selected segment | `#686866` |
| push button | `#605F5E` |
| output well | `#1E1E1E` |
| slider track / knob | `#403F3D` / `#959594` |
| checkbox (off/on) | `#555553` / `#959594` (gray check style) |
| success green | `#32D74B` (systemGreen, dark) |
| caption text | `#71706F` |

---

## 3. Typography

| Role | Font | Size / weight | Notes |
|---|---|---|---|
| Window title | SF Pro Text | 13 pt semibold | left-aligned after sidebar-toggle icon |
| Tab-strip label | SF Pro Text | 12 pt regular, gray | centered in strip |
| Sidebar file rows | SF Pro Text | 13 pt regular | 24 pt row height, dark `#232323`-class text |
| Sidebar header (project name) | SF Pro Text | 13 pt semibold | with back-chevron |
| Status bar | Mono (editor font) | ≈ 11–12 pt | chips use the mono face, bold in mode badge |
| Editor | **JetBrainsMono Nerd Font Mono** | **14 pt**, line-spacing **1.0×** | from Settings ▸ Editor; ligatures ON |
| Quick-open title / path | SF Pro Text | 13 pt regular / 11 pt regular gray | two-line rows |
| Context menu | SF Pro Text | 13 pt regular | native menu metrics (22 pt rows) |
| Settings labels | SF Pro Text | 13 pt regular; bold section labels | macOS forms style |
| Preview prose | SF Pro Text | ≈ 15 px body, GitHub CSS ramp | h1 ≈ 28 pt bold + hairline rule |
| Preview code | mono (same family) | ≈ 13 px | GitHub-style chips/blocks |

The editor status "NORMAL" badge uses a Nerd-Font Vim glyph before the word; file
rows use colored Nerd-Font/devicon file-type glyphs (JS = yellow, npm = red,
JSON braces = yellow, README = blue ⓘ, CLAUDE.md = blue crest).

---

## 4. Per-screenshot specification


Anatomy, top to bottom:

1. **Titlebar row** (≈ 46 pt, `#F0F0EE`, opaque, no vibrancy):
   traffic lights → sidebar-toggle icon (rounded-square split-pane glyph, gray) →
   window/workspace title "scopecreeplabs-site" (13 pt semibold, dark). Right:
   clock glyph + "Trial — 14 days remaining" (11 pt gray `#8A8A8C`*≈*).
2. **Tab strip row** (≈ 28 pt, same `#F0F0EE`, hairline `#EDEDEB→#DADADB` below):
   centered workspace label "scopecreeplabs-site" in 12 pt gray `#A2A3A5`; far
   right a **`+` button** (`#ADAEAF` glyph) to create a workspace/tab. With a
   single tab it renders as a full-width strip with a centered label (no tab
   outline, no close button visible).
3. **Content row** (three panes, separated by 1 px `#DADADB` hairlines):
   - **Sidebar** ≈ 370 pt, `#FFFFFF`. Header row (≈ 28 pt): `‹` back chevron,
     project name semibold, then right-aligned icon set: `+` (new file), refresh
     `↻`, locate/target `⌖`, new-folder `⊞`. Tree rows 24 pt, ~17 pt indent per
     level, gray disclosure chevrons, gray folder glyphs, colored file-type
     glyphs. Selected row = full-width `#EAEAEA` fill, square edges.
   - **Editor** (Neovim grid on `#FFFFFF`): gutter ≈ 40 pt with right-aligned
     **hybrid relative line numbers** (current line absolute "15", others
     relative) in light gray; text `#041420`; block cursor as a filled light-gray
     cell (`≈#D2D2D3`) over the glyph; a highlighted span/line renders as a
     `#EEF0F1` band. No visible scrollbar at rest (overlay style).
   - **Markdown preview pane** ≈ 550 pt: header row (≈ 30 pt, white, hairline
     below) with "Markdown Preview" 13 pt `#8D8F91` left and refresh `↻` right.
     Content = GitHub-light rendered markdown: `#F6F8FA` code blocks (6 pt
     radius), inline-code chips, blockquote with left bar, ruled tables,
     h1/h2 with bottom hairlines. 24 pt content padding.
4. **Status bar** (≈ 26 pt, `#FFFFFF`, hairline above, mono font, powerline
   styling with angled chip edges):
   - Left: Vim-glyph + "NORMAL" white-on-`#004DC8` badge (angled right edge) →
     doc-icon + "README.md" chip on `#E2E3E5` → branch glyph + "main" in dimmed
     gray (no fill).
   - Right: red folder glyph + "scopecreeplabs-site" project chip (`#E2E3E5`-class
     bg, red accent icon) → "15/9" **line/col indicator** white-on-`#005A37`
     green cap that runs to the window edge.

### 4.2 `tabs.png` — workspace overview (light)

Invoking the tab overview replaces the window content with a **workspace switcher
grid** (Safari-tab-overview style):

- Canvas `#E0E0DF`, only traffic lights remain top-left (no title).
- Grid of live **workspace thumbnail cards**, 4 per row, ≈ 408 × 256 pt, starting
  ≈ 48 pt below the titlebar with ≈ 22 pt gaps. Each card: a 22 pt mini-titlebar
  strip (`#ECECEB`, centered workspace name in ≈ 11 pt gray-dark text) above a
  live miniature render of that workspace's window (sidebar/editor/status bar all
  visible). Cards have square-ish corners (≤ 4 pt radius), 1 px border, no heavy
  shadow.
  i.e. **one card per workspace (window/nvim instance), each with its own project**.
- Next row: a **"+" card** at the same size — `#ECECEB` empty titlebar strip, body
  in slightly darker gray, large centered `+` glyph `#4E4E4D` (~64 pt stroke
  weight ≈ 4 pt). Clicking creates a new workspace.

### 4.3 `quick-open.png` — file palette (light)

- **Scrim:** all content *below the tab strip* (sidebar, editor, preview, status
  bar) is dimmed by a ~30 % black overlay (white → `#B2B2B2`); the titlebar/tab
  strip merely take inactive appearance (`#F0F0EE` → `#E2E2E1`). The palette is a
  key borderless panel floating above.
- **Panel:** ≈ 498 × 346 pt, top edge ≈ 96 pt below the tab strip (upper-center,
  Spotlight-like), horizontally centered on the *window*, ≈ 10 pt corner radius,
  `#ECECEC` fill, soft shadow. **Fixed height** — unused area below the results
  stays empty panel.
- **Search row** (≈ 34 pt, `#FFFFFF`, hairline below): gray magnifier glyph,
  13 pt query text ("index") with I-beam caret, right-aligned live count
  "32 files" in `#A9A9AA`, then a circular ✕ clear button (gray).
- **Result rows** (≈ 44 pt, two-line): document glyph (16 pt, gray outline) →
  title "index.astro" 13 pt near-black → path `src/pages/index.astro` 11 pt
  `#7D7E7F` below. Selected row = `#DBDBDB` full-width fill, square edges. No
  visible fuzzy-match character highlighting in the capture (titles render
  uniformly) — matched-range emphasis is optional.
- Behavior implied: type-to-filter across project files, ↑↓ to select, ⏎ opens.

### 4.4 `file-context-menu.png` — sidebar context menu (light)

Right-click on a file row (row shows `#EAEAEA` selection behind the menu):

- **Menu:** ≈ 216 pt wide, `#E3E3E2` fill (menu material), ≈ 10 pt radius, soft
  shadow, 22 pt item height, 13 pt `#232323` labels, ~14 pt horizontal padding.
  **No icons.** Shortcuts right-aligned in mid-gray using macOS glyphs.
- Items and grouping (inset hairline separators between groups):
  1. `Copy ⌘C` · `Cut ⌘X`
  2. `Rename ↩` · `Delete ⌘⌫`
  3. `Copy Path` · `Reveal in Finder` · `Open with Default App`
- Metrics/spacing match a native `NSMenu` (Big Sur+ style); building it as a
  literal `NSMenu` is acceptable and preferred.
- This crop also confirms sidebar specs: 24 pt rows, colored type glyphs, header
  icon row, white bg.

### 4.5 `settings-general.png` — Settings ▸ General (dark)

Native **toolbar-style preferences window** (≈ 463 × 491 pt, not resizable in
appearance):

- Title = active pane name ("General"). Toolbar shows icon-above-label tiles:
  **General** (gear, selected: `#474544` rounded tile, icon+label `#1186FF`) and
  **Editor** (pencil, unselected: `#9B9B9A`). Titlebar+toolbar band `#3A3837`,
  body `#2B2A28`, separated by a hairline.
- Body is label-left/control-right forms with hairline-separated sections
  (≈ 22 pt margins):
  1. **Theme:** 3-segment control `System | Light | Dark` — track `#363533`,
     selected segment `#686866`, labels light gray.
  2. **Neovim Path:** rounded text field (`#363533`, light text
     `/usr/local/bin/nvim`) + folder-icon button + `Auto-detect` + `Verify`
     push buttons (`#605F5E`, 5 pt radius). Below: status line with green
     checkmark `#32D74B` + "Valid executable".
  3. **Verify Output:** label + read-only mono well (`#1E1E1E`, ~13 px mono,
     scrollable) showing `nvim --version` output.
  4. **File Associations:** `Set as Default for Code Files` button + caption
     (`#71706F`).

### 4.6 `settings-editor.png` — Settings ▸ Editor (dark)

Same window shell, Editor pane selected (pencil icon `#1186FF`):

- **Use Neovim Configuration** checkbox (off) + caption: "When enabled, font
  settings are controlled by your Neovim config (guifont option)." — i.e. GUI
  font settings are a *native override* of `guifont`, with a switch to defer to
  the user's nvim config. Hairline below.
- **Font Family:** full-width popup button (`#1E1E1E`, chevron right) —
  "JetBrainsMono Nerd Font Mono".
- **Font Size:** tick-marked slider (track `#403F3D`, gray knob `#959594`) +
  right value label "14 pt".
- **Line Spacing:** tick-marked slider + "1.0x".
- **Use Ligatures** checkbox (checked; gray check style, not accent-tinted).

Superlemon adopts this pane's spacing and native presentation, but not its
second preference store. Its implementation selects the Neovim init and opens
`$XDG_CONFIG_HOME/superlemon/init.vim`; font, ligature, and chrome values live
there so file configuration remains authoritative.

### 4.7 `image-viewer.png` — image file viewer (light)

Selecting an image file in the tree opens a **native image viewer occupying the
entire content area right of the sidebar** (no editor grid, no preview pane, and
no tab-strip row in this capture — the header is a single titlebar row):

- Canvas: flat `#ECECEC` (no checkerboard), edge-to-edge.
- Image centered, rendered at a fitted size with its own alpha (the app icon's
  rounded-rect shape floats directly on the canvas; no frame or border).
- **Info bar** (bottom, ≈ 30 pt, `#ECECEC`, hairline above): left-aligned
  metadata segments separated by hairline dividers —
  `icon_256x256.png · PNG · 192 × 192 · 49 KB · Dec 19, 2025 at 2:22 PM`
  in ≈ 11 pt gray; far right an "open-external" glyph button (↗ in a square)
  to open with the default app.
- No visible zoom controls/percentage in the capture (zoom UI optional/gesture
  driven).
- Sidebar confirms deep-nesting behavior: 8+ indent levels remain legible within
  the 370 pt width.

### 4.8 `dark-mode.png` — main window, dark

Identical anatomy to §4.1 with the §2.2 palette. Deltas called out in §6.

---

## 5. Component inventory (implementation checklist)

| Component | Spec summary |
|---|---|
| **Window chrome** | Standard titlebar with `titlebarAppearsTransparent`-style flat band (`#F0F0EE` / `#373736`), traffic lights standard, title left-aligned next to a sidebar-toggle button; trial/status pill right. Second 28 pt strip for tabs. Content squares off below a hairline. |
| **Tab strip** | Full-width band under titlebar; single-tab state = centered gray workspace label + right `+` button; drives workspaces (one per window/nvim). Overview mode (§4.2) is the many-tabs affordance. |
| **Sidebar (file tree)** | 370 pt fixed-ish width, white/`#1E1E1E`; header: back chevron, project name, 4 action icons (new file, refresh, locate current file, new folder); 24 pt rows, 17 pt indents, colored Nerd-Font type icons, full-width selection fill (`#EAEAEA`/`#343434`); context menu per §4.4; opens image viewer for images, buffers for text. |
| **Editor surface** | Neovim grid; hybrid relative numbers in 40 pt gutter; block cursor filled cell; overlay scrollbars (hidden at rest); colorscheme owns all editor colors. |
| **Status bar** | 26 pt native bar, mono font, powerline-angled chips: mode badge (color-by-mode; NORMAL = `#004DC8`/slate), file chip, branch label (dimmed), project chip, line/col cap chip (green). Light: saturated bg + white text; dark: pastel bg + near-black text. |
| **Quick-open palette** | 498 × 346 pt fixed panel, upper-center; white search row w/ live count + clear button; 44 pt two-line result rows (icon, name, dimmed path); `#DBDBDB`/dark selection; 30 % black scrim over content region only. |
| **Context menus** | Native NSMenu appearance: 216 pt, 22 pt rows, no icons, right-aligned shortcut glyphs, grouped by separators. |
| **Settings** | Compact toolbar-prefs window, panes General/Editor; title follows pane; native controls (segmented, text field, push buttons, popup, tick sliders, checkboxes, read-only mono well); dark surface `#2B2A28`, accent system blue. |
| **Image viewer** | Flat `#ECECEC` canvas, centered image, bottom metadata bar with hairline-separated fields + open-external button. |
| **Workspace overview** | Full-window grid of live thumbnails + "+" card on `#E0E0DF`. |
| **Markdown preview** | Right pane, header row w/ title + refresh, GitHub-flavored rendering; light = GitHub-light on white, dark = GitHub-dark `#0D1117` (intentionally darker than the chrome). |
| **Scrollbars** | Overlay style everywhere; none visible at rest in any capture. |

---

## 6. Dark-mode delta (beyond palette swap)

1. **Chrome vs. editor decouple.** Light mode is uniformly white, so chrome and
   editor blend. Dark mode exposes the seams deliberately: neutral chrome
   (`#1E1E1E`/`#373736`), **colorscheme-owned editor bg** (`#1B2023`), and an even
   darker preview (`#0D1117`). Superlemon must not force one background across
   regions — chrome derives from appearance, editor derives from nvim highlights.
2. **Hairlines invert to pure black** (`#DADADB` → `#000000`) — separation by
   darkness rather than lightness; no elevation/shadow changes.
3. **Chip contrast strategy flips.** Light: saturated fills + white text
   (`#004DC8`, `#005A37`). Dark: desaturated pastels + near-black text
   (`#ADC694`, `#C79595`, slate `≈#66788A`). Recompute chip colors per
   appearance; don't just dim them.
4. **Selection fills keep constant ΔL** (~8 %: `#EAEAEA` on white ↔ `#343434` on
   `#1E1E1E`).
5. **Settings window uses a warmer dark** (`#2B2A28`/`#3A3837`) than the main
   chrome — consistent with a standard `NSAppearance` dark window rather than the
   editor palette.
6. Theme is user-selectable (System/Light/Dark segmented control in Settings),
   independent of the nvim colorscheme.

---

## 7. Mapping to Superlemon architecture

Ownership per DESIGN.md's package split:

|---|---|---|
| Window frame, titlebar band, trial pill, sidebar toggle | **ShellKit** | window/session layer (§10) |
| File-tree sidebar + header actions + context menu | **ShellKit** (new module; see deltas) | native `NSOutlineView`-class component, not nvim-rendered |
| Editor grid, gutter, cursor, line highlight | **SurfaceKit / GridKit** | already specified (§5–6) |
| Status bar (mode badge, chips) | **ChromeKit** | feeds off `ext_messages` ruler/showmode + runtime-plugin state (git branch, line/col) |
| Context menus (native metrics) | **ChromeKit** primitives, invoked by ShellKit sidebar | plain `NSMenu` is sufficient |
| Settings window (General/Editor) | **ShellKit** | chooses the Neovim init and creates/opens `$XDG_CONFIG_HOME/superlemon/init.vim`; no duplicate native preference values |
| Image viewer + metadata bar | **ShellKit** (new; see deltas) | bypasses nvim for binary files |
| Markdown preview pane | **ShellKit/ChromeKit** (new; see deltas) | WKWebView-or-native render with GitHub CSS, refresh control |
| Scrim + palette materials | **ChromeKit** | borderless key `NSPanel` + 30 % black overlay view over content region |


Flagging explicitly, as required:

1. **Native file-tree sidebar (ShellKit).** DESIGN.md §1 Non-Goals defers custom
   header actions, colored type icons, selection, context menu, rename/delete
   file ops) a **core identity feature**. Requires a new ShellKit module
   (`SidebarKit` or similar) plus runtime-plugin RPC for open/rename/delete and
   "locate current file".
   GitHub-styled right pane with its own header and refresh. Implies a ShellKit
   split-view host that can mount non-grid panes beside `GridSurfaceView`.
3. **Native image viewer.** Not in DESIGN.md. Opening a binary/image from the
   sidebar must route to a native viewer pane (canvas + metadata bar) instead of
   an nvim buffer.
4. **Workspace overview / tab semantics.** DESIGN.md maps `ext_tabline` to nvim
   windows, one nvim each)** with live thumbnails and a "+" card. Superlemon
   needs a ShellKit workspace switcher distinct from (or layered over) the
   ChromeKit tabline; decide whether the strip shows tabpages, workspaces, or
   both.
5. **Quick-open is a file palette, not just ext_cmdline.** DESIGN §8 specifies a
   and two-line rows — the `goto_anything()` runtime-plugin function needs a
   first-class ChromeKit UI and a file index (or FZF-style scan) independent of
   nvim's cmdline.
6. **Status bar is richer than `msg_ruler`.** Powerline-style chips need git
   branch, line/col, project name, and mode pushed from the runtime plugin;
   DESIGN §8 only sketches a "slim native status bar". Also adopt the
   light/dark chip contrast flip (§6.3).
   controls, but Superlemon deliberately keeps font, spacing, ligatures, and
   chrome in `$XDG_CONFIG_HOME/superlemon/init.vim`. The native window chooses
   the Neovim init and opens that annotated file; it does not create a second
   source of truth. Neovim binary verification and file associations can remain
   native because they are needed before Neovim starts.
8. **Trial/licensing surface.** The "Trial — 14 days remaining" titlebar pill
   implies licensing UI — absent from DESIGN.md; note for productization.
9. **Flat-opaque chrome, not vibrancy-first.** DESIGN.md leans on
   for menu/palette-class surfaces. Keep titlebar/sidebar/status opaque flat
   fills per §2 tokens.

---

## 8. Quick-reference geometry sheet

| Measure | Value |
|---|---|
| Titlebar row height | ≈ 46 pt |
| Tab strip height | ≈ 28 pt |
| Sidebar width | ≈ 370 pt |
| Sidebar row height / indent | 24 pt / 17 pt |
| Sidebar header height | ≈ 28 pt |
| Editor gutter width | ≈ 40 pt |
| Preview pane width (at 1790 pt window) | ≈ 550 pt |
| Preview header height | ≈ 30 pt |
| Status bar height | ≈ 26 pt |
| Quick-open panel | 498 × 346 pt; search row 34 pt; result row 44 pt; radius ≈ 10 pt |
| Context menu | 216 pt wide; 22 pt rows; radius ≈ 10 pt |
| Settings window | ≈ 463 × 491 pt; toolbar tile ≈ 54 × 44 pt, radius 6 pt |
| Overview card | ≈ 408 × 256 pt; mini titlebar 22 pt |
| Image-viewer info bar | ≈ 30 pt |
| Window corner radius | ≈ 10 pt (system) |
| Hairlines | 1 px, `#DADADB` light / `#000000` dark |
