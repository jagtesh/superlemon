package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"

	app "go.hasen.dev/shirei/app"

	. "go.hasen.dev/shirei"
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

	defaultBackground := colorVec(snapshot.DefaultBG, Vec4{220, 12, 10, 1})
	Container(Attrs(Viewport, BackgroundVec(defaultBackground)), func() {
		Container(Attrs(Row, CrossMid, Pad2(8, 12), Gap(12), Background(220, 18, 16, 1)), func() {
			Label(title, FontSize(13), FontWeight(WeightBold), TextColor(0, 0, 94, 1))
			Label(modeLabel(snapshot.Mode), FontSize(12), TextColor(45, 75, 70, 1))
			Label(fmt.Sprintf("%d:%d", snapshot.Cursor.Row+1, snapshot.Cursor.Col+1), FontSize(12), TextColor(0, 0, 68, 1))
		})

		if snapshot.Error != "" {
			Container(Attrs(Pad(12), Background(0, 65, 35, 1)), func() {
				Label(snapshot.Error, TextColor(0, 0, 100, 1))
			})
		}

		renderGrid(snapshot)
	})
}

const (
	gridCellWidth  = float32(8.25)
	gridCellHeight = float32(17)
)

func renderGrid(snapshot Snapshot) {
	defaultForeground := colorVec(snapshot.DefaultFG, Vec4{0, 0, 90, 1})
	defaultBackground := colorVec(snapshot.DefaultBG, Vec4{220, 12, 10, 1})
	Container(Attrs(Expand, NoAnimate, BackgroundVec(defaultBackground)), func() {
		for row, cells := range snapshot.Rows {
			row := row
			Container(Attrs(Row, FixHeight(gridCellHeight), NoAnimate), func() {
				for col, cell := range cells {
					renderCell(cell, row, col, snapshot.Cursor, defaultForeground, defaultBackground)
				}
			})
		}
	})
}

func renderCell(cell GridCell, row, col int, cursor Cursor, defaultFG, defaultBG Vec4) {
	foreground := colorVec(cell.Highlight.Foreground, defaultFG)
	background := colorVec(cell.Highlight.Background, defaultBG)
	isCursor := cursor.Visible && cursor.Row == row && cursor.Col == col
	if isCursor && cursor.Shape == "block" {
		foreground, background = background, foreground
	}

	textOptions := []TextAttrsFn{
		FontSize(14), Fonts(Monospace...), TextColorVec(foreground),
	}
	if cell.Highlight.Bold {
		textOptions = append(textOptions, FontWeight(WeightBold))
	}
	if cell.Highlight.Italic {
		textOptions = append(textOptions, FontStyle(StyleItalic))
	}
	text := cell.Text
	if text == "" {
		text = " "
	}
	Container(Attrs(FixSize(gridCellWidth, gridCellHeight), NoAnimate, BackgroundVec(background)), func() {
		Label(text, textOptions...)
		if !isCursor || cursor.Shape == "block" {
			return
		}
		percentage := float32(max(1, min(100, cursor.Percentage))) / 100
		switch cursor.Shape {
		case "horizontal":
			height := gridCellHeight * percentage
			Element(Attrs(Float(0, gridCellHeight-height), FixSize(gridCellWidth, height), BackgroundVec(foreground)))
		default: // vertical
			Element(Attrs(Float(0, 0), FixSize(gridCellWidth*percentage, gridCellHeight), BackgroundVec(foreground)))
		}
	})
}

func colorVec(color NvimColor, fallback Vec4) Vec4 {
	if !color.Valid {
		return fallback
	}
	r := float64((color.RGB>>16)&0xff) / 255
	g := float64((color.RGB>>8)&0xff) / 255
	b := float64(color.RGB&0xff) / 255
	maximum := math.Max(r, math.Max(g, b))
	minimum := math.Min(r, math.Min(g, b))
	lightness := (maximum + minimum) / 2
	if maximum == minimum {
		return Vec4{0, float32(0), float32(lightness * 100), 1}
	}
	delta := maximum - minimum
	saturation := delta / (1 - math.Abs(2*lightness-1))
	var hue float64
	switch maximum {
	case r:
		hue = math.Mod((g-b)/delta, 6)
	case g:
		hue = (b-r)/delta + 2
	default:
		hue = (r-g)/delta + 4
	}
	hue *= 60
	if hue < 0 {
		hue += 360
	}
	return Vec4{float32(hue), float32(saturation * 100), float32(lightness * 100), 1}
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
