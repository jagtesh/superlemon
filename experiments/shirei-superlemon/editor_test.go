package main

import (
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestDisplayTextMarksCursor(t *testing.T) {
	snapshot := Snapshot{Row: 1, Col: 1, Lines: []string{"one", "two"}}
	if got, want := snapshot.DisplayText(), "one\nt▏wo"; got != want {
		t.Fatalf("DisplayText() = %q, want %q", got, want)
	}
}

func TestLinegridRedrawProducesNeovimScreen(t *testing.T) {
	screen := &grid{}
	changed := applyRedraw(screen, []any{
		[]any{"grid_resize", []any{int64(1), int64(8), int64(3)}},
		[]any{"grid_line", []any{int64(1), int64(0), int64(0), []any{
			[]any{"h", int64(0)}, []any{"i", int64(0)}, []any{" ", int64(0), int64(2)},
		}}},
		[]any{"grid_cursor_goto", []any{int64(1), int64(0), int64(2)}},
		[]any{"flush", []any{}},
	})
	if !changed {
		t.Fatal("redraw did not change the screen")
	}
	if got, want := screen.snapshot().DisplayText(), "hi▏\n\n"; got != want {
		t.Fatalf("screen = %q, want %q", got, want)
	}
}

func TestEmbeddedNeovimAcceptsCommand(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is not available")
	}
	editor := NewEditor(t.TempDir(), nil)
	editor.Start()
	defer editor.Close()

	waitFor := func(match string) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if strings.Contains(editor.Snapshot().DisplayText(), match) {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		snapshot := editor.Snapshot()
		t.Fatalf("Neovim screen never contained %q; error=%q screen:\n%s", match, snapshot.Error, snapshot.DisplayText())
	}

	waitFor("~")
	editor.Input(":echo 'shirei-command-ok'<CR>")
	waitFor("shirei-command-ok")
}
