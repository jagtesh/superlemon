package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/neovim/go-client/nvim"
	shirei "go.hasen.dev/shirei"
)

type NvimColor struct {
	RGB   uint32
	Valid bool
}

type Highlight struct {
	Foreground NvimColor
	Background NvimColor
	Bold       bool
	Italic     bool
	Underline  bool
	Reverse    bool
}

type GridCell struct {
	Text      string
	Highlight Highlight
}

type Cursor struct {
	Row        int
	Col        int
	Shape      string
	Percentage int
	Visible    bool
}

type Snapshot struct {
	Mode      string
	Name      string
	Rows      [][]GridCell
	Cursor    Cursor
	DefaultFG NvimColor
	DefaultBG NvimColor
	Error     string
}

type gridCell struct {
	text string
	hlID int
}

type modeInfo struct {
	shape      string
	percentage int
}

type grid struct {
	width, height int
	rows          [][]gridCell
	cursorRow     int
	cursorCol     int
	title         string
	mode          string
	modeIndex     int
	modes         []modeInfo
	highlights    map[int]Highlight
	defaultFG     NvimColor
	defaultBG     NvimColor
}

func newGrid() *grid {
	return &grid{
		highlights: make(map[int]Highlight),
		defaultFG:  NvimColor{RGB: 0xd8dee9, Valid: true},
		defaultBG:  NvimColor{RGB: 0x151820, Valid: true},
	}
}

func (g *grid) resize(width, height int) {
	old := g.rows
	g.width, g.height = width, height
	g.rows = make([][]gridCell, height)
	for row := range g.rows {
		g.rows[row] = make([]gridCell, width)
		for col := range g.rows[row] {
			g.rows[row][col].text = " "
			if row < len(old) && col < len(old[row]) {
				g.rows[row][col] = old[row][col]
			}
		}
	}
}

func (g *grid) clear() {
	for row := range g.rows {
		for col := range g.rows[row] {
			g.rows[row][col] = gridCell{text: " "}
		}
	}
}

func (g *grid) snapshot() Snapshot {
	rows := make([][]GridCell, len(g.rows))
	for row := range g.rows {
		rows[row] = make([]GridCell, len(g.rows[row]))
		for col, cell := range g.rows[row] {
			highlight := g.highlights[cell.hlID]
			if highlight.Reverse {
				highlight.Foreground, highlight.Background = highlight.Background, highlight.Foreground
			}
			rows[row][col] = GridCell{Text: cell.text, Highlight: highlight}
		}
	}
	cursor := Cursor{Row: g.cursorRow, Col: g.cursorCol, Shape: "block", Percentage: 100, Visible: true}
	if g.modeIndex >= 0 && g.modeIndex < len(g.modes) {
		cursor.Shape = g.modes[g.modeIndex].shape
		cursor.Percentage = g.modes[g.modeIndex].percentage
	}
	if cursor.Shape == "" {
		cursor.Shape = "block"
	}
	if cursor.Percentage <= 0 {
		cursor.Percentage = 100
	}
	return Snapshot{
		Mode: g.mode, Name: g.title, Rows: rows, Cursor: cursor,
		DefaultFG: g.defaultFG, DefaultBG: g.defaultBG,
	}
}

type Editor struct {
	cwd       string
	arguments []string
	inputs    chan string
	stop      chan struct{}
	done      chan struct{}
	snapshot  atomic.Pointer[Snapshot]
}

func NewEditor(cwd string, arguments []string) *Editor {
	editor := &Editor{
		cwd: cwd, arguments: append([]string(nil), arguments...),
		inputs: make(chan string, 256), stop: make(chan struct{}), done: make(chan struct{}),
	}
	editor.store(Snapshot{Mode: "starting"})
	return editor
}

func (e *Editor) Start() { go e.supervise() }

func (e *Editor) Close() {
	select {
	case <-e.stop:
	default:
		close(e.stop)
	}
	<-e.done
}

func (e *Editor) Input(input string) {
	select {
	case e.inputs <- input:
	default:
	}
}

func (e *Editor) Snapshot() Snapshot { return *e.snapshot.Load() }

func (e *Editor) store(snapshot Snapshot) {
	if current := e.snapshot.Load(); current != nil && snapshotsEqual(*current, snapshot) {
		return
	}
	e.snapshot.Store(&snapshot)
	shirei.RequestNextFrame()
}

func snapshotsEqual(left, right Snapshot) bool {
	if left.Mode != right.Mode || left.Name != right.Name || left.Cursor != right.Cursor ||
		left.DefaultFG != right.DefaultFG || left.DefaultBG != right.DefaultBG || left.Error != right.Error ||
		len(left.Rows) != len(right.Rows) {
		return false
	}
	for row := range left.Rows {
		if !slices.Equal(left.Rows[row], right.Rows[row]) {
			return false
		}
	}
	return true
}

func (e *Editor) supervise() {
	defer close(e.done)
	delay := 100 * time.Millisecond
	for {
		select {
		case <-e.stop:
			return
		default:
		}

		err := e.runSession()
		select {
		case <-e.stop:
			return
		default:
		}
		log.Printf("Neovim session stopped: %v; restarting in %s", err, delay)
		e.store(Snapshot{Mode: "restarting", Error: fmt.Sprintf("Neovim stopped: %v", err)})
		timer := time.NewTimer(delay)
		select {
		case <-e.stop:
			timer.Stop()
			return
		case <-timer.C:
		}
		delay = min(delay*2, 3*time.Second)
	}
}

func (e *Editor) runSession() error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	binary := os.Getenv("SUPERLEMON_NVIM")
	if binary == "" {
		binary = "nvim"
	}
	arguments := append([]string{"--embed"}, e.arguments...)
	logf := func(string, ...any) {}
	if os.Getenv("SUPERLEMON_SHIREI_DEBUG") != "" {
		logf = log.Printf
	}
	client, err := nvim.NewChildProcess(
		nvim.ChildProcessCommand(binary),
		nvim.ChildProcessArgs(arguments...),
		nvim.ChildProcessDir(e.cwd),
		nvim.ChildProcessEnv(os.Environ()),
		nvim.ChildProcessContext(ctx),
		nvim.ChildProcessLogf(logf),
	)
	if err != nil {
		return err
	}
	defer client.Close()

	redraw := make(chan [][]any, 256)
	if err := client.RegisterHandler("redraw", func(updates ...[]any) {
		if os.Getenv("SUPERLEMON_SHIREI_DEBUG") != "" {
			log.Printf("redraw updates=%d first=%#v", len(updates), updates[0][0])
		}
		select {
		case redraw <- updates:
		case <-ctx.Done():
		}
	}); err != nil {
		return err
	}
	if err := client.AttachUI(110, 36, map[string]any{
		"ext_linegrid": true,
		"rgb":          true,
	}); err != nil {
		return err
	}

	screen := newGrid()
	health := time.NewTicker(time.Second)
	defer health.Stop()
	for {
		select {
		case <-e.stop:
			return nil
		case <-health.C:
			if _, err := client.Mode(); err != nil {
				return fmt.Errorf("Neovim health check failed: %w", err)
			}
		case updates := <-redraw:
			if applyRedraw(screen, updates) {
				e.store(screen.snapshot())
			}
		case input := <-e.inputs:
			if input == "" {
				continue
			}
			if _, err := client.Input(input); err != nil {
				return err
			}
		}
	}
}

func applyRedraw(screen *grid, updates [][]any) bool {
	flushed := false
	for _, event := range updates {
		if len(event) == 0 {
			continue
		}
		name, _ := event[0].(string)
		if name == "flush" && len(event) == 1 {
			flushed = true
			continue
		}
		for _, rawInvocation := range event[1:] {
			invocation, _ := rawInvocation.([]any)
			switch name {
			case "grid_resize":
				if len(invocation) >= 3 && intValue(invocation[0]) == 1 {
					screen.resize(intValue(invocation[1]), intValue(invocation[2]))
				}
			case "grid_clear":
				if len(invocation) >= 1 && intValue(invocation[0]) == 1 {
					screen.clear()
				}
			case "grid_cursor_goto":
				if len(invocation) >= 3 && intValue(invocation[0]) == 1 {
					screen.cursorRow = intValue(invocation[1])
					screen.cursorCol = intValue(invocation[2])
				}
			case "grid_line":
				applyGridLine(screen, invocation)
			case "default_colors_set":
				if len(invocation) >= 2 {
					screen.defaultFG = colorValue(invocation[0])
					screen.defaultBG = colorValue(invocation[1])
				}
			case "hl_attr_define":
				applyHighlight(screen, invocation)
			case "mode_info_set":
				applyModeInfo(screen, invocation)
			case "mode_change":
				if len(invocation) >= 2 {
					screen.mode, _ = invocation[0].(string)
					screen.modeIndex = intValue(invocation[1])
				}
			case "set_title":
				if len(invocation) >= 1 {
					screen.title, _ = invocation[0].(string)
				}
			case "flush":
				flushed = true
			}
		}
	}
	return flushed
}

func applyGridLine(screen *grid, invocation []any) {
	if len(invocation) < 4 || intValue(invocation[0]) != 1 {
		return
	}
	row, col := intValue(invocation[1]), intValue(invocation[2])
	if row < 0 || row >= len(screen.rows) {
		return
	}
	cells, _ := invocation[3].([]any)
	hlID := 0
	for _, rawCell := range cells {
		cell, _ := rawCell.([]any)
		if len(cell) == 0 {
			continue
		}
		text, _ := cell[0].(string)
		if len(cell) >= 2 {
			hlID = intValue(cell[1])
		}
		repeat := 1
		if len(cell) >= 3 {
			repeat = max(1, intValue(cell[2]))
		}
		for range repeat {
			if col >= 0 && col < len(screen.rows[row]) {
				screen.rows[row][col] = gridCell{text: text, hlID: hlID}
			}
			col++
		}
	}
}

func applyHighlight(screen *grid, invocation []any) {
	if len(invocation) < 2 {
		return
	}
	attributes, _ := invocation[1].(map[string]any)
	highlight := Highlight{
		Foreground: colorFromMap(attributes, "foreground"),
		Background: colorFromMap(attributes, "background"),
		Bold:       boolFromMap(attributes, "bold"), Italic: boolFromMap(attributes, "italic"),
		Underline: boolFromMap(attributes, "underline"), Reverse: boolFromMap(attributes, "reverse"),
	}
	screen.highlights[intValue(invocation[0])] = highlight
}

func applyModeInfo(screen *grid, invocation []any) {
	if len(invocation) < 2 {
		return
	}
	items, _ := invocation[1].([]any)
	screen.modes = make([]modeInfo, len(items))
	for index, raw := range items {
		item, _ := raw.(map[string]any)
		shape, _ := item["cursor_shape"].(string)
		screen.modes[index] = modeInfo{shape: shape, percentage: intValue(item["cell_percentage"])}
	}
}

func colorValue(value any) NvimColor {
	number := intValue(value)
	if number < 0 {
		return NvimColor{}
	}
	return NvimColor{RGB: uint32(number), Valid: true}
}

func colorFromMap(values map[string]any, key string) NvimColor {
	value, ok := values[key]
	if !ok {
		return NvimColor{}
	}
	return colorValue(value)
}

func boolFromMap(values map[string]any, key string) bool {
	value, _ := values[key].(bool)
	return value
}

func intValue(value any) int {
	switch number := value.(type) {
	case int:
		return number
	case int8:
		return int(number)
	case int16:
		return int(number)
	case int32:
		return int(number)
	case int64:
		return int(number)
	case uint:
		return int(number)
	case uint8:
		return int(number)
	case uint16:
		return int(number)
	case uint32:
		return int(number)
	case uint64:
		return int(number)
	default:
		return 0
	}
}

func modeLabel(mode string) string {
	switch {
	case strings.HasPrefix(mode, "i"):
		return "INSERT"
	case strings.HasPrefix(mode, "v") || mode == "V" || mode == "\x16":
		return "VISUAL"
	case strings.HasPrefix(mode, "c"):
		return "COMMAND"
	case strings.HasPrefix(mode, "R"):
		return "REPLACE"
	default:
		return "NORMAL"
	}
}
