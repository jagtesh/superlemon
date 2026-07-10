// ShellKit: native workspace chrome — file-tree sidebar, Powerline status bar,
// quick-open palette. See DESIGN.md §14 and NORTHSTAR.md for exact geometry,
// and Sources/ShellKit/WIRING.md for how the app embeds each component.
//
// Components:
//   FuzzyScorer              — pure fzy-style subsequence scorer (nonisolated)
//   FileIndex                — actor; project file walk + gitignore + queries
//   StatusBarView            — 24pt powerline status bar fed by superlemon.status
//   FileTreeSidebarView      — lazy NSOutlineView file tree + context menu
//   FileOperations           — FileManager mutations behind sidebar callbacks
