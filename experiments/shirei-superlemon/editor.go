package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
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
	row := s.Row - 1
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

	if err := e.refresh(rpc); err != nil {
		return err
	}
	for {
		select {
		case <-e.stop:
			// The deferred kill is deliberate: shutdown must not hang if Neovim
			// is wedged and unable to answer a graceful RPC request.
			return nil
		case err := <-rpc.failed:
			return err
		case input := <-e.inputs:
			if input == "" {
				continue
			}
			if _, err := rpc.request("nvim_input", []any{input}); err != nil {
				return err
			}
			if err := e.refresh(rpc); err != nil {
				return err
			}
		}
	}
}

func (e *Editor) refresh(rpc *rpcClient) error {
	const script = `
local b = vim.api.nvim_get_current_buf()
local c = vim.api.nvim_win_get_cursor(0)
return {
  vim.api.nvim_get_mode().mode,
  c[1], c[2],
  vim.api.nvim_buf_get_name(b),
  vim.api.nvim_buf_get_lines(b, 0, -1, false),
}`
	value, err := rpc.request("nvim_exec_lua", []any{script, []any{}})
	if err != nil {
		return err
	}
	parts, ok := value.([]any)
	if !ok || len(parts) != 5 {
		return fmt.Errorf("unexpected snapshot: %T", value)
	}
	linesRaw, _ := parts[4].([]any)
	lines := make([]string, 0, len(linesRaw))
	for _, line := range linesRaw {
		lines = append(lines, stringValue(line))
	}
	e.store(Snapshot{
		Mode: stringValue(parts[0]), Row: intValue(parts[1]), Col: intValue(parts[2]),
		Name: stringValue(parts[3]), Lines: lines,
	})
	return nil
}

type rpcClient struct {
	encoder *msgpack.Encoder
	decoder *msgpack.Decoder
	writes  sync.Mutex
	mu      sync.Mutex
	nextID  uint64
	pending map[uint64]chan rpcResponse
	failed  chan error
}

type rpcResponse struct {
	value any
	err   error
}

func newRPC(stdin io.Writer, stdout io.Reader) *rpcClient {
	return &rpcClient{
		encoder: msgpack.NewEncoder(stdin), decoder: msgpack.NewDecoder(bufio.NewReader(stdout)),
		pending: make(map[uint64]chan rpcResponse), failed: make(chan error, 1),
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
