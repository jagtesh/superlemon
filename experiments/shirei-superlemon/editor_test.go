package main

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/neovim/go-client/nvim"
)

func TestGoClientReceivesRedraw(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is not available")
	}
	client, err := nvim.NewChildProcess(
		nvim.ChildProcessArgs("--embed", "--clean"),
		nvim.ChildProcessContext(context.Background()),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	redraw := make(chan struct{}, 1)
	if err := client.RegisterHandler("redraw", func(updates ...[]any) {
		select {
		case redraw <- struct{}{}:
		default:
		}
	}); err != nil {
		t.Fatal(err)
	}
	if err := client.AttachUI(80, 24, map[string]any{"ext_linegrid": true, "rgb": true}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-redraw:
	case <-time.After(2 * time.Second):
		t.Fatal("go-client received no redraw notification")
	}
}

func snapshotText(snapshot Snapshot) string {
	var text strings.Builder
	for row, cells := range snapshot.Rows {
		if row > 0 {
			text.WriteByte('\n')
		}
		for _, cell := range cells {
			text.WriteString(cell.Text)
		}
	}
	return text.String()
}

func TestLinegridRedrawPreservesCursorModeAndHighlights(t *testing.T) {
	screen := newGrid()
	flushed := applyRedraw(screen, [][]any{
		{"grid_resize", []any{int64(1), int64(8), int64(3)}},
		{"default_colors_set", []any{int64(0xd8dee9), int64(0x151820), int64(0)}},
		{"hl_attr_define", []any{int64(7), map[string]any{
			"foreground": int64(0xffffff), "background": int64(0x663399), "bold": true,
		}, map[string]any{}, []any{}}},
		{"mode_info_set", []any{true, []any{
			map[string]any{"cursor_shape": "block", "cell_percentage": int64(100)},
			map[string]any{"cursor_shape": "vertical", "cell_percentage": int64(25)},
		}}},
		{"mode_change", []any{"insert", int64(1)}},
		{"grid_line", []any{int64(1), int64(0), int64(0), []any{
			[]any{"h", int64(7)}, []any{"i"}, []any{" ", int64(0), int64(2)},
		}}},
		{"grid_cursor_goto", []any{int64(1), int64(0), int64(2)}},
		{"flush"},
	})
	if !flushed {
		t.Fatal("redraw did not flush")
	}
	snapshot := screen.snapshot()
	if snapshot.Cursor.Row != 0 || snapshot.Cursor.Col != 2 {
		t.Fatalf("cursor = %#v", snapshot.Cursor)
	}
	if snapshot.Cursor.Shape != "vertical" || snapshot.Cursor.Percentage != 25 {
		t.Fatalf("insert cursor = %#v", snapshot.Cursor)
	}
	if !snapshot.Rows[0][0].Highlight.Bold || snapshot.Rows[0][1].Highlight.Background.RGB != 0x663399 {
		t.Fatalf("highlight run was not preserved: %#v", snapshot.Rows[0][:2])
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
			if strings.Contains(snapshotText(editor.Snapshot()), match) {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		snapshot := editor.Snapshot()
		t.Fatalf("Neovim screen never contained %q; error=%q screen:\n%s", match, snapshot.Error, snapshotText(snapshot))
	}

	waitFor("~")
	editor.Input(":echo 'shirei-command-ok'<CR>")
	waitFor("shirei-command-ok")
}
