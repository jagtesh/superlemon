// ChromeKit: nvim's externalized cmdline, popupmenu, and messages rendered as
// native AppKit components, plus a retained ext_tabline model. The shipped
// native buffer strip is runtime-driven. See DESIGN.md §8/§14, NORTHSTAR.md
// for the visual direction, and WIRING.md for current integration.
//
// Layout of the module:
//   Models.swift                   — value types (CmdlineModel, PopupMenuModel,
//                                    MessageModel, TablineModel, Chunk)
//   ChromeState.swift              — @MainActor consumer of RedrawBatch;
//                                    the single source of truth for chrome
//   CmdlineRenderer.swift          — pure model -> NSAttributedString mapping
//   CmdlinePanelController.swift   — floating cmdline palette (NSPanel)
//   PopupMenuPanelController.swift — completion popup (NSPanel + NSTableView)
//   MessageToastController.swift   — replacing toast + history (plain NSViews)
import NvimKit
