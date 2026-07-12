package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	app "go.hasen.dev/shirei/app"

	. "go.hasen.dev/shirei"
	. "go.hasen.dev/shirei/widgets"
)

var editor *Editor

func main() {
	workingDirectory, err := os.Getwd()
	if err != nil {
		workingDirectory = "."
	}

	arguments := os.Args[1:]
	editor = NewEditor(workingDirectory, arguments)
	editor.Start()
	defer editor.Close()

	app.SetupWindow("Superlemon Shirei PoC", 920, 680)
	app.Run(rootView)
}

func rootView() {
	if input := frameInput(); input != "" {
		editor.Input(input)
	}

	snapshot := editor.Snapshot()
	title := "Superlemon · Shirei proof of concept"
	if snapshot.Name != "" {
		title += " · " + filepath.Base(snapshot.Name)
	}

	Container(Attrs(Viewport, Background(220, 12, 10, 1)), func() {
		Container(Attrs(Row, CrossMid, Pad2(8, 12), Gap(12), Background(220, 18, 16, 1)), func() {
			Label(title, FontSize(13), FontWeight(WeightBold), TextColor(0, 0, 94, 1))
			Label(strings.ToUpper(snapshot.Mode), FontSize(12), TextColor(45, 75, 70, 1))
			Label(fmt.Sprintf("%d:%d", snapshot.Row, snapshot.Col+1), FontSize(12), TextColor(0, 0, 68, 1))
		})

		if snapshot.Error != "" {
			Container(Attrs(Pad(12), Background(0, 65, 35, 1)), func() {
				Label(snapshot.Error, TextColor(0, 0, 100, 1))
			})
		}

		LargeText(snapshot.DisplayText(), TextAttrs(
			FontSize(14),
			Fonts(Monospace...),
			TextColor(0, 0, 90, 1),
		))
	})
}

func frameInput() string {
	mods := InputState.Modifiers
	key := FrameInput.Key
	if key >= KeyA && key <= KeyZ && mods&(ModCtrl|ModCmd) != 0 {
		prefix := "C"
		if mods&ModCmd != 0 {
			prefix = "D"
		}
		return fmt.Sprintf("<%s-%c>", prefix, 'a'+rune(key-KeyA))
	}

	if notation := specialKeyNotation(key); notation != "" {
		return notation
	}
	return strings.ReplaceAll(FrameInput.Text, "<", "<lt>")
}

func specialKeyNotation(key KeyCode) string {
	switch key {
	case KeyLeft:
		return "<Left>"
	case KeyRight:
		return "<Right>"
	case KeyUp:
		return "<Up>"
	case KeyDown:
		return "<Down>"
	case KeyEnter:
		return "<CR>"
	case KeyEscape:
		return "<Esc>"
	case KeyDeleteBackward:
		return "<BS>"
	case KeyDeleteForward:
		return "<Del>"
	case KeyHome:
		return "<Home>"
	case KeyEnd:
		return "<End>"
	case KeyPageUp:
		return "<PageUp>"
	case KeyPageDown:
		return "<PageDown>"
	case KeyTab:
		return "<Tab>"
	default:
		return ""
	}
}
