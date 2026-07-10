// ChromeKit: nvim's externalized UI (ext_cmdline, ext_popupmenu, ext_messages,
// ext_tabline) rendered as native AppKit components. See DESIGN.md §8/§14 and
// NORTHSTAR.md for the visual language, and WIRING.md (this directory) for
// how the app integrates the pieces.
//
// Layout of the module:
//   Models.swift                   — value types (CmdlineModel, PopupMenuModel,
//                                    MessageModel, TablineModel, Chunk)
//   ChromeState.swift              — @MainActor consumer of RedrawBatch;
//                                    the single source of truth for chrome
//   CmdlineRenderer.swift          — pure model -> NSAttributedString mapping
//   CmdlinePanelController.swift   — floating cmdline palette (NSPanel)
//   PopupMenuPanelController.swift — completion popup (NSPanel + NSTableView)
//   MessageToastController.swift   — stacking message toasts (plain NSViews)
import NvimKit
