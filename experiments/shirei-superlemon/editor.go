package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/vmihailenco/msgpack/v5"
	shirei "go.hasen.dev/shirei"
)

type Snapshot struct {
	Mode  string
	Row   int
	Col   int
	Name  string
	Lines []string
	Error string
}

func (s Snapshot) DisplayText() string {
	if len(s.Lines) == 0 {
		return "Starting Neovim…"
	}
	lines := append([]string(nil), s.Lines...)
	row := s.Row
	if row >= 0 && row < len(lines) {
		col := min(max(s.Col, 0), len(lines[row]))
		lines[row] = lines[row][:col] + "▏" + lines[row][col:]
	}
	text := ""
	for index, line := range lines {
		if index > 0 {
			text += "\n"
		}
		text += line
	}
	return text
}

type grid struct {
	width, height int
	rows          [][]string
	cursorRow     int
	cursorCol     int
	title         string
}

func (g *grid) resize(width, height int) {
	g.width, g.height = width, height
	g.rows = make([][]string, height)
	for row := range g.rows {
		g.rows[row] = make([]string, width)
		for col := range g.rows[row] {
			g.rows[row][col] = " "
		}
	}
}

func (g *grid) clear() {
	g.resize(g.width, g.height)
}

func (g *grid) snapshot() Snapshot {
	lines := make([]string, len(g.rows))
	for row, cells := range g.rows {
		lines[row] = strings.TrimRight(strings.Join(cells, ""), " ")
	}
	return Snapshot{
		Mode: "nvim", Row: g.cursorRow, Col: g.cursorCol,
		Name: g.title, Lines: lines,
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

func (e *Editor) Snapshot() Snapshot {
	return *e.snapshot.Load()
}

func (e *Editor) store(snapshot Snapshot) {
	e.snapshot.Store(&snapshot)
	shirei.RequestNextFrame()
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
	binary := os.Getenv("SUPERLEMON_NVIM")
	if binary == "" {
		binary = "nvim"
	}
	arguments := []string{"--embed"}
	arguments = append(arguments, e.arguments...)
	command := exec.Command(binary, arguments...)
	command.Dir = e.cwd
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		return err
	}

	rpc := newRPC(stdin, stdout)
	if err := command.Start(); err != nil {
		return err
	}
	defer func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	}()
	go io.Copy(io.Discard, stderr)
	go rpc.readLoop()

	if _, err := rpc.request("nvim_ui_attach", []any{
		110, 36, map[string]any{"ext_linegrid": true, "rgb": true},
	}); err != nil {
		return err
	}
	screen := &grid{}
	for {
		select {
		case <-e.stop:
			// The deferred kill is deliberate: shutdown must not hang if Neovim
			// is wedged and unable to answer a graceful RPC request.
			return nil
		case err := <-rpc.failed:
			return err
		case notification := <-rpc.notifications:
			if notification.method == "redraw" && applyRedraw(screen, notification.params) {
				e.store(screen.snapshot())
			}
		case input := <-e.inputs:
			if input == "" {
				continue
			}
			if _, err := rpc.request("nvim_input", []any{input}); err != nil {
				return err
			}
		}
	}
}

func applyRedraw(screen *grid, params []any) bool {
	changed := false
	for _, rawEvent := range params {
		event, ok := rawEvent.([]any)
		if !ok || len(event) == 0 {
			continue
		}
		name := stringValue(event[0])
		// Zero-argument redraw events are encoded as only their event name.
		if name == "flush" && len(event) == 1 {
			changed = true
			continue
		}
		for _, rawInvocation := range event[1:] {
			invocation, _ := rawInvocation.([]any)
			switch name {
			case "grid_resize":
				if len(invocation) >= 3 && intValue(invocation[0]) == 1 {
					screen.resize(intValue(invocation[1]), intValue(invocation[2]))
					changed = true
				}
			case "grid_clear":
				if len(invocation) >= 1 && intValue(invocation[0]) == 1 {
					screen.clear()
					changed = true
				}
			case "grid_cursor_goto":
				if len(invocation) >= 3 && intValue(invocation[0]) == 1 {
					screen.cursorRow = intValue(invocation[1])
					screen.cursorCol = intValue(invocation[2])
					changed = true
				}
			case "grid_line":
				applyGridLine(screen, invocation)
				changed = true
			case "set_title":
				if len(invocation) >= 1 {
					screen.title = stringValue(invocation[0])
					changed = true
				}
			case "flush":
				changed = true
			}
		}
	}
	return changed
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
	for _, rawCell := range cells {
		cell, _ := rawCell.([]any)
		if len(cell) == 0 {
			continue
		}
		text, repeat := stringValue(cell[0]), 1
		if len(cell) >= 3 {
			repeat = max(1, intValue(cell[2]))
		}
		for range repeat {
			if col >= 0 && col < len(screen.rows[row]) {
				screen.rows[row][col] = text
			}
			col++
		}
	}
}

type rpcClient struct {
	encoder       *msgpack.Encoder
	decoder       *msgpack.Decoder
	writes        sync.Mutex
	mu            sync.Mutex
	nextID        uint64
	pending       map[uint64]chan rpcResponse
	failed        chan error
	notifications chan rpcNotification
}

type rpcNotification struct {
	method string
	params []any
}

type rpcResponse struct {
	value any
	err   error
}

func newRPC(stdin io.Writer, stdout io.Reader) *rpcClient {
	return &rpcClient{
		encoder: msgpack.NewEncoder(stdin), decoder: msgpack.NewDecoder(bufio.NewReader(stdout)),
		pending: make(map[uint64]chan rpcResponse), failed: make(chan error, 1),
		notifications: make(chan rpcNotification, 256),
	}
}

func (r *rpcClient) request(method string, params []any) (any, error) {
	r.mu.Lock()
	r.nextID++
	id := r.nextID
	response := make(chan rpcResponse, 1)
	r.pending[id] = response
	r.mu.Unlock()

	r.writes.Lock()
	err := r.encoder.Encode([]any{0, id, method, params})
	r.writes.Unlock()
	if err != nil {
		return nil, err
	}
	result := <-response
	return result.value, result.err
}

func (r *rpcClient) readLoop() {
	for {
		var message []any
		if err := r.decoder.Decode(&message); err != nil {
			r.fail(err)
			return
		}
		if len(message) == 3 && intValue(message[0]) == 2 {
			params, _ := message[2].([]any)
			r.notifications <- rpcNotification{method: stringValue(message[1]), params: params}
			continue
		}
		if len(message) != 4 || intValue(message[0]) != 1 {
			continue
		}
		id := uint64(intValue(message[1]))
		r.mu.Lock()
		response := r.pending[id]
		delete(r.pending, id)
		r.mu.Unlock()
		if response == nil {
			continue
		}
		if message[2] != nil {
			response <- rpcResponse{err: fmt.Errorf("Neovim RPC: %v", message[2])}
		} else {
			response <- rpcResponse{value: message[3]}
		}
	}
}

func (r *rpcClient) fail(err error) {
	if errors.Is(err, io.EOF) {
		err = errors.New("Neovim exited")
	}
	r.mu.Lock()
	for id, response := range r.pending {
		response <- rpcResponse{err: err}
		delete(r.pending, id)
	}
	r.mu.Unlock()
	select {
	case r.failed <- err:
	default:
	}
}

func intValue(value any) int {
	switch number := value.(type) {
	case int8:
		return int(number)
	case int16:
		return int(number)
	case int32:
		return int(number)
	case int64:
		return int(number)
	case uint8:
		return int(number)
	case uint16:
		return int(number)
	case uint32:
		return int(number)
	case uint64:
		return int(number)
	case int:
		return number
	default:
		return 0
	}
}

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}
