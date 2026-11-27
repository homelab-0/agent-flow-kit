package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ProtocolVersion is the MCP version AFK asks for.
const ProtocolVersion = "2025-06-18"

// Tool is one tool a server offers.
type Tool struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

type rpcResp struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func rpc(id int, method string, params any) []byte {
	m := map[string]any{"jsonrpc": "2.0", "method": method}
	if id > 0 {
		m["id"] = id
	}
	if params != nil {
		m["params"] = params
	}
	b, _ := json.Marshal(m)
	return b
}

var initParams = map[string]any{
	"protocolVersion": ProtocolVersion,
	"capabilities":    map[string]any{},
	"clientInfo":      map[string]any{"name": "afk", "version": "1"},
}

// ListTools connects to a server, initializes, and lists its tools. The
// bearer token, when the server takes one, is read from its variable here
// and only sent to the server.
func ListTools(ctx context.Context, s Server, getenv func(string) string) ([]Tool, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var raw json.RawMessage
	var err error
	if s.Kind == "http" {
		raw, err = httpTools(ctx, s, getenv)
	} else {
		raw, err = stdioTools(ctx, s)
	}
	if err != nil {
		return nil, err
	}
	var res struct {
		Tools []Tool `json:"tools"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, fmt.Errorf("tools/list: %w", err)
	}
	return res.Tools, nil
}

func decodeResult(r rpcResp, what string) (json.RawMessage, error) {
	if r.Error != nil {
		return nil, fmt.Errorf("%s: %s (%d)", what, r.Error.Message, r.Error.Code)
	}
	return r.Result, nil
}

func httpTools(ctx context.Context, s Server, getenv func(string) string) (json.RawMessage, error) {
	token := ""
	if s.BearerEnv != "" {
		if token = getenv(s.BearerEnv); token == "" {
			return nil, fmt.Errorf("%s is not set, so there is no token to send", s.BearerEnv)
		}
	}
	session := ""
	post := func(body []byte, want bool) (rpcResp, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.URL, bytes.NewReader(body))
		if err != nil {
			return rpcResp{}, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		req.Header.Set("MCP-Protocol-Version", ProtocolVersion)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if session != "" {
			req.Header.Set("Mcp-Session-Id", session)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return rpcResp{}, err
		}
		defer resp.Body.Close()
		if id := resp.Header.Get("Mcp-Session-Id"); id != "" {
			session = id
		}
		if resp.StatusCode/100 != 2 {
			return rpcResp{}, fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		if !want {
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
			return rpcResp{}, nil
		}
		body2 := io.LimitReader(resp.Body, 16<<20)
		if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
			return readSSE(body2)
		}
		var r rpcResp
		err = json.NewDecoder(body2).Decode(&r)
		return r, err
	}
	r, err := post(rpc(1, "initialize", initParams), true)
	if err != nil {
		return nil, fmt.Errorf("initialize: %w", err)
	}
	if _, err := decodeResult(r, "initialize"); err != nil {
		return nil, err
	}
	if _, err := post(rpc(0, "notifications/initialized", nil), false); err != nil {
		return nil, fmt.Errorf("initialized: %w", err)
	}
	r, err = post(rpc(2, "tools/list", map[string]any{}), true)
	if err != nil {
		return nil, fmt.Errorf("tools/list: %w", err)
	}
	return decodeResult(r, "tools/list")
}

// readSSE takes the first JSON-RPC response from an event stream.
func readSSE(r io.Reader) (rpcResp, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 16<<20)
	var data strings.Builder
	flush := func() (rpcResp, bool) {
		defer data.Reset()
		var resp rpcResp
		if data.Len() == 0 || json.Unmarshal([]byte(data.String()), &resp) != nil || len(resp.ID) == 0 {
			return resp, false
		}
		return resp, true
	}
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if resp, ok := flush(); ok {
				return resp, nil
			}
		case strings.HasPrefix(line, "data:"):
			data.WriteString(strings.TrimPrefix(strings.TrimPrefix(line, "data:"), " "))
		}
	}
	if resp, ok := flush(); ok {
		return resp, nil
	}
	return rpcResp{}, errors.New("the event stream ended without a response")
}

func stdioTools(ctx context.Context, s Server) (json.RawMessage, error) {
	cmd := exec.CommandContext(ctx, s.Command, s.Args...)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	defer func() {
		_ = in.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 64<<10), 16<<20)
	call := func(id int, method string, params any) (json.RawMessage, error) {
		if _, err := in.Write(append(rpc(id, method, params), '\n')); err != nil {
			return nil, err
		}
		for sc.Scan() {
			var r rpcResp
			if json.Unmarshal(sc.Bytes(), &r) != nil || string(r.ID) != fmt.Sprint(id) {
				continue // a log line or a notification
			}
			return decodeResult(r, method)
		}
		msg := strings.TrimSpace(stderr.String())
		if len(msg) > 300 {
			msg = msg[len(msg)-300:]
		}
		if ctx.Err() != nil {
			return nil, fmt.Errorf("%s: no answer in time", method)
		}
		if msg != "" {
			return nil, fmt.Errorf("%s: the server exited: %s", method, msg)
		}
		return nil, fmt.Errorf("%s: the server exited", method)
	}
	if _, err := call(1, "initialize", initParams); err != nil {
		return nil, err
	}
	if _, err := in.Write(append(rpc(0, "notifications/initialized", nil), '\n')); err != nil {
		return nil, err
	}
	return call(2, "tools/list", map[string]any{})
}
