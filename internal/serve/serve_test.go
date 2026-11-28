package serve

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
)

// rig is an afk serve whose CLIs are never run: answer stands in for them.
type rig struct {
	t      *testing.T
	home   string
	url    string
	store  *apikey.Store
	runs   string
	mu     sync.Mutex
	ran    [][]string
	dirs   []string
	envs   [][]string
	answer func(argv []string) ([]byte, []byte, int)
}

func newRig(t *testing.T, planRuns bool) *rig {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"claude", "codex", "grok"} {
		if err := os.WriteFile(filepath.Join(bin, h), []byte("#!/bin/sh\necho 1.0.0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := map[string]string{"AFK_ROUTER_SIGNALS_FILE": filepath.Join(home, "signals.json"), "AFK_SKIP_BENCHMARK_AUTOSYNC": "1"}
	if planRuns {
		cfg := filepath.Join(home, ".config", "afk", "config.toml")
		if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(cfg, []byte("version = 1\n\n[serve]\nplan_runs = true\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	r := &rig{t: t, home: home, runs: filepath.Join(home, "runs")}
	r.answer = func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"result","is_error":false,"result":"hello there"}` + "\n"), nil, 0
	}
	c := &core.Core{
		Home: home, Getenv: func(k string) string { return env[k] }, Cwd: home,
		Harness:   harness.Env{Home: home, Path: bin, BinDir: bin, OS: runtime.GOOS, Getenv: func(string) string { return "" }},
		Environ:   func() []string { return []string{"PATH=/usr/bin"} },
		Installed: func(string) bool { return true },
		Now:       func() time.Time { return time.Unix(1764158400, 0) },
		Accounts: func(_ context.Context, h string) (harness.Account, bool) {
			if h == "grok" {
				return harness.Account{Models: []string{"grok-5", "grok-code"}, ModelsKnown: true, DefaultModel: "grok-5", At: 1764158400}, true
			}
			return harness.Account{}, false
		},
		Headless: func(_ context.Context, argv, env []string, dir string) ([]byte, []byte, int) {
			r.mu.Lock()
			r.ran, r.dirs, r.envs = append(r.ran, argv), append(r.dirs, dir), append(r.envs, env)
			answer := r.answer
			r.mu.Unlock()
			return answer(argv)
		},
	}
	r.store = &apikey.Store{Path: filepath.Join(home, "keys.json")}
	srv := &Server{Keys: r.store, Limiter: &apikey.Limiter{}, Version: "test", Ping: time.Hour,
		Backend: &CoreBackend{Core: c, RunsDir: r.runs, TempDir: t.TempDir()}}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	r.url = ts.URL
	return r
}

func (r *rig) key(n apikey.New) string {
	r.t.Helper()
	_, token, err := r.store.Create(n)
	if err != nil {
		r.t.Fatal(err)
	}
	return token
}

func (r *rig) post(path, token, body string, hdr ...string) (*http.Response, string) {
	r.t.Helper()
	req, _ := http.NewRequest("POST", r.url+path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func (r *rig) lastRun() (argv []string, dir string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.ran) == 0 {
		r.t.Fatal("no CLI was run")
	}
	return r.ran[len(r.ran)-1], r.dirs[len(r.dirs)-1]
}

func (r *rig) runCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.ran)
}

const hi = `{"model":"afk/auto","messages":[{"role":"user","content":"say hi"}]}`

func TestAuth(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	for name, tok := range map[string]string{"none": "", "wrong": "afk_00000000_" + strings.Repeat("0", 64), "not a key": "sk-123"} {
		resp, body := r.post("/v1/chat/completions", tok, hi)
		if resp.StatusCode != 401 || !strings.Contains(body, "authentication_error") {
			t.Errorf("%s: %d %s", name, resp.StatusCode, body)
		}
	}
	if _, err := r.store.Revoke("gw"); err != nil {
		t.Fatal(err)
	}
	if resp, _ := r.post("/v1/chat/completions", token, hi); resp.StatusCode != 401 {
		t.Errorf("a revoked key: %d", resp.StatusCode)
	}
	if r.runCount() != 0 {
		t.Error("a CLI ran without a key")
	}
	// An Anthropic client sends the key in x-api-key and gets its own
	// error shape.
	resp, body := r.post("/v1/messages", "", hi, "x-api-key", "nope")
	if resp.StatusCode != 401 || !strings.Contains(body, `"type":"error"`) {
		t.Errorf("anthropic: %d %s", resp.StatusCode, body)
	}
}

func TestRouterKeyAnswersReadOnlyInAThrowawayFolder(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	resp, body := r.post("/v1/chat/completions", token, `{"model":"afk/auto","temperature":0.2,"messages":[{"role":"system","content":"Be brief."},{"role":"user","content":"say hi"}]}`)
	if resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	var out struct {
		Model   string
		Choices []struct {
			Message struct{ Role, Content string }
			Finish  string `json:"finish_reason"`
		}
		Usage any
		AFK   struct{ Harness, Model, Run string }
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	if out.Model != "afk/auto" || len(out.Choices) != 1 || out.Choices[0].Message.Content != "hello there" || out.Choices[0].Finish != "stop" {
		t.Errorf("answer %s", body)
	}
	// The stub reported no usage, so none is made up.
	if out.Usage != nil {
		t.Errorf("usage %v", out.Usage)
	}
	if out.AFK.Harness == "" || resp.Header.Get("X-AFK-Route") != out.AFK.Harness+"/"+out.AFK.Model {
		t.Errorf("route %+v header %q", out.AFK, resp.Header.Get("X-AFK-Route"))
	}
	if resp.Header.Get("X-AFK-Ignored") != "temperature" {
		t.Errorf("ignored %q", resp.Header.Get("X-AFK-Ignored"))
	}
	argv, dir := r.lastRun()
	line := strings.Join(argv, " ")
	if !strings.Contains(line, "Be brief.") || !strings.Contains(line, "say hi") {
		t.Errorf("the prompt lost a message: %v", argv)
	}
	if !strings.Contains(line, "plan") && !strings.Contains(line, "read-only") {
		t.Errorf("the run is not read-only: %v", argv)
	}
	if dir == r.home || !strings.Contains(filepath.Base(dir), "afk-serve-") {
		t.Errorf("ran in %s", dir)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("the throwaway folder is still there: %v", err)
	}
	// The run is on record under the key's name.
	recs := runrec.Load(r.runs, time.Time{})
	if len(recs) != 1 || recs[0].Where != "serve" || recs[0].Key != "gw" || recs[0].ID != out.AFK.Run {
		t.Errorf("records %+v", recs)
	}
}

func TestPlanRunsOffKeepsSignInsOut(t *testing.T) {
	r := newRig(t, false)
	router := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	grok := r.key(apikey.New{Name: "grok", Kind: apikey.KindHarness, Harness: "grok"})
	for name, c := range map[string][2]string{"router": {router, hi}, "harness": {grok, `{"model":"grok/grok-5","messages":[{"role":"user","content":"hi"}]}`}} {
		resp, body := r.post("/v1/chat/completions", c[0], c[1])
		if resp.StatusCode != 403 || !strings.Contains(body, "serve.plan_runs") {
			t.Errorf("%s: %d %s", name, resp.StatusCode, body)
		}
	}
	if r.runCount() != 0 {
		t.Error("a CLI ran on its sign-in with plan runs off")
	}
}

func TestHarnessKeyRunsTheNamedModel(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "grok", Kind: apikey.KindHarness, Harness: "grok", Limits: &apikey.Limits{}})
	ask := func(model string) (*http.Response, string) {
		return r.post("/v1/chat/completions", token, `{"model":"`+model+`","messages":[{"role":"user","content":"hi"}]}`)
	}
	for model, want := range map[string]string{"grok/grok-code": "grok-code", "grok-code": "grok-code", "grok/default": "grok-5", "default": "grok-5"} {
		resp, body := ask(model)
		if resp.StatusCode != 200 {
			t.Fatalf("%s: %d %s", model, resp.StatusCode, body)
		}
		argv, _ := r.lastRun()
		if filepath.Base(argv[0]) != "grok" || !strings.Contains(strings.Join(argv, " "), "-m "+want+" ") {
			t.Errorf("%s ran %v", model, argv)
		}
	}
	n := r.runCount()
	for _, model := range []string{"grok/grok-9", "afk/auto", "claude/sonnet", "--yolo"} {
		if resp, body := ask(model); resp.StatusCode != 404 && resp.StatusCode != 400 {
			t.Errorf("%s: %d %s", model, resp.StatusCode, body)
		}
	}
	if r.runCount() != n {
		t.Error("a model the key can't name was run")
	}

	// The list is what the CLI reported, under the key's harness.
	req, _ := http.NewRequest("GET", r.url+"/v1/models", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	for _, id := range []string{`"grok/default"`, `"grok/grok-5"`, `"grok/grok-code"`} {
		if !strings.Contains(string(b), id) {
			t.Errorf("models %s lacks %s", b, id)
		}
	}
	if strings.Contains(string(b), "afk/auto") {
		t.Errorf("a harness key lists router models: %s", b)
	}

	// A key limited to some models reaches only those.
	lim := r.key(apikey.New{Name: "one", Kind: apikey.KindHarness, Harness: "grok", Models: []string{"grok-code"}})
	if resp, body := r.post("/v1/chat/completions", lim, `{"model":"grok/grok-5","messages":[{"role":"user","content":"hi"}]}`); resp.StatusCode != 404 {
		t.Errorf("outside the key's models: %d %s", resp.StatusCode, body)
	}
}

func TestRouterKeyModels(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	if resp, body := r.post("/v1/chat/completions", token, `{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}`); resp.StatusCode != 404 || !strings.Contains(body, "afk/auto") {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
	if resp, body := r.post("/v1/chat/completions", token, `{"model":"afk/review","messages":[{"role":"user","content":"look at this"}]}`); resp.StatusCode != 200 {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
}

func TestLimitsAnswer429(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter, Limits: &apikey.Limits{PerMinute: 1}})
	if resp, body := r.post("/v1/chat/completions", token, hi); resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	resp, body := r.post("/v1/chat/completions", token, hi)
	if resp.StatusCode != 429 || resp.Header.Get("Retry-After") == "" || !strings.Contains(body, "rate_limit_error") {
		t.Errorf("%d %q %s", resp.StatusCode, resp.Header.Get("Retry-After"), body)
	}
	if r.runCount() != 1 {
		t.Errorf("%d runs", r.runCount())
	}
	// Turning the limit off takes effect on the next call.
	if _, err := r.store.SetLimits("gw", apikey.Limits{}); err != nil {
		t.Fatal(err)
	}
	if resp, body := r.post("/v1/chat/completions", token, hi); resp.StatusCode != 200 {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
}

func TestACLIsOwnLimitIsA429(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "grok", Kind: apikey.KindHarness, Harness: "grok"})
	r.answer = func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"error","message":"429 rate limit exceeded"}`), nil, 1
	}
	resp, body := r.post("/v1/chat/completions", token, `{"model":"grok/grok-5","messages":[{"role":"user","content":"hi"}]}`)
	if resp.StatusCode != 429 || resp.Header.Get("Retry-After") == "" {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
	r.answer = func([]string) ([]byte, []byte, int) { return nil, []byte("segfault"), 139 }
	if resp, body := r.post("/v1/chat/completions", token, `{"model":"grok/grok-5","messages":[{"role":"user","content":"hi"}]}`); resp.StatusCode != 502 || !strings.Contains(body, "segfault") {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
}

func TestBadRequests(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter, Limits: &apikey.Limits{}})
	big := strings.Repeat("x", MaxPrompt+1)
	for name, c := range map[string]struct {
		body string
		want int
	}{
		"not json":      {`{`, 400},
		"no messages":   {`{"model":"afk/auto","messages":[]}`, 400},
		"an image":      {`{"model":"afk/auto","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"x"}}]}]}`, 400},
		"a forced tool": {`{"model":"afk/auto","tool_choice":"required","messages":[{"role":"user","content":"hi"}]}`, 400},
		"two answers":   {`{"model":"afk/auto","n":2,"messages":[{"role":"user","content":"hi"}]}`, 400},
		"only a system": {`{"model":"afk/auto","messages":[{"role":"system","content":"x"}]}`, 400},
		"too long":      {`{"model":"afk/auto","messages":[{"role":"user","content":"` + big + `"}]}`, 413},
	} {
		if resp, body := r.post("/v1/chat/completions", token, c.body); resp.StatusCode != c.want {
			t.Errorf("%s: %d %s", name, resp.StatusCode, cutText(body, 200))
		}
	}
	if r.runCount() != 0 {
		t.Error("a bad request reached a CLI")
	}
}

// events reads a server-sent stream's data lines.
func events(t *testing.T, r *rig, path, token, body string) []string {
	t.Helper()
	req, _ := http.NewRequest("POST", r.url+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/event-stream" {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("%d %s %s", resp.StatusCode, resp.Header.Get("Content-Type"), b)
	}
	var out []string
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		if d, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
			out = append(out, d)
		}
	}
	return out
}

const claudeStream = `{"type":"system","subtype":"init","session_id":"abcd-1234"}
{"type":"stream_event","event":{"type":"message_start"},"parent_tool_use_id":null}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}},"parent_tool_use_id":null}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}},"parent_tool_use_id":null}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sub"}},"parent_tool_use_id":"toolu_1"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}},"parent_tool_use_id":null}
{"type":"result","is_error":false,"result":"Hello","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":7}}
`

func TestStreamsOpenAI(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "claude", Kind: apikey.KindHarness, Harness: "claude", Models: []string{"sonnet"}})
	r.answer = func([]string) ([]byte, []byte, int) { return []byte(claudeStream), nil, 0 }
	ev := events(t, r, "/v1/chat/completions", token, `{"model":"claude/sonnet","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}`)
	text := ""
	var usage map[string]any
	finished := false
	for _, e := range ev {
		if e == "[DONE]" {
			continue
		}
		var c struct {
			Choices []struct {
				Delta  struct{ Content string }
				Finish *string `json:"finish_reason"`
			}
			Usage map[string]any
		}
		if err := json.Unmarshal([]byte(e), &c); err != nil {
			t.Fatalf("%s: %v", e, err)
		}
		for _, ch := range c.Choices {
			text += ch.Delta.Content
			finished = finished || (ch.Finish != nil && *ch.Finish == "stop")
		}
		if c.Usage != nil {
			usage = c.Usage
		}
	}
	if text != "Hello" || !finished || ev[len(ev)-1] != "[DONE]" {
		t.Errorf("text %q finished %v events %v", text, finished, ev)
	}
	// The CLI's own count, cache reads included.
	if usage["prompt_tokens"] != float64(100) || usage["completion_tokens"] != float64(7) {
		t.Errorf("usage %v", usage)
	}
	// The run asked the CLI for its partial output.
	argv, _ := r.lastRun()
	if !strings.Contains(strings.Join(argv, " "), "--include-partial-messages") {
		t.Errorf("argv %v", argv)
	}
	// And to give up on a refused request soon: a caller is waiting.
	r.mu.Lock()
	env := strings.Join(r.envs[len(r.envs)-1], "\n")
	r.mu.Unlock()
	if !strings.Contains(env, "CLAUDE_CODE_MAX_RETRIES=2") {
		t.Error("a served Claude Code run keeps its ten retries")
	}
}

func TestStreamsAnthropicInOnePieceWhenTheCLICannotStream(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "grok", Kind: apikey.KindHarness, Harness: "grok"})
	ev := events(t, r, "/v1/messages", token, `{"model":"grok/grok-5","max_tokens":100,"stream":true,"system":"Be brief.","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}`)
	var types []string
	text := ""
	for _, e := range ev {
		var m struct {
			Type  string
			Delta struct{ Text string }
		}
		if err := json.Unmarshal([]byte(e), &m); err != nil {
			t.Fatal(err)
		}
		types = append(types, m.Type)
		text += m.Delta.Text
	}
	if strings.Join(types, " ") != "message_start content_block_start content_block_delta content_block_stop message_delta message_stop" || text != "hello there" {
		t.Errorf("types %v text %q", types, text)
	}
}

func TestAnthropicAnswer(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	resp, body := r.post("/v1/messages", "", `{"model":"afk/auto","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, "x-api-key", token, "anthropic-version", "2023-06-01")
	if resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	var out struct {
		Type, Role string
		Content    []struct{ Type, Text string }
		StopReason string `json:"stop_reason"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	if out.Type != "message" || out.Role != "assistant" || len(out.Content) != 1 || out.Content[0].Text != "hello there" || out.StopReason != "end_turn" {
		t.Errorf("%s", body)
	}
	// No usage came from the CLI: the required counts are zero and the
	// header says they aren't a measurement.
	if resp.Header.Get("X-AFK-Usage") != "not-reported" || resp.Header.Get("X-AFK-Ignored") != "max_tokens" {
		t.Errorf("headers %v", resp.Header)
	}
}

func TestAStreamThatFailsPartWayEndsWithAnError(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "gw", Kind: apikey.KindRouter})
	r.answer = func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Half an"}}}
{"type":"result","is_error":true,"result":"connection lost"}
`), nil, 1
	}
	ev := events(t, r, "/v1/chat/completions", token, `{"model":"afk/auto","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	joined := strings.Join(ev, "\n")
	if !strings.Contains(joined, "Half an") || !strings.Contains(joined, `"error"`) {
		t.Errorf("events %v", ev)
	}
	// Part of an answer was already sent, so no other route was tried.
	routes := map[string]bool{}
	r.mu.Lock()
	for _, a := range r.ran {
		routes[filepath.Base(a[0])] = true
	}
	r.mu.Unlock()
	if len(routes) != 1 {
		t.Errorf("failed over after sending text: %v", routes)
	}
}

func TestKeyWithAFolderWorksThere(t *testing.T) {
	r := newRig(t, true)
	work := t.TempDir()
	token := r.key(apikey.New{Name: "agent", Kind: apikey.KindHarness, Harness: "claude", Models: []string{"sonnet"}, Dir: work, Mode: "edits"})
	if resp, body := r.post("/v1/chat/completions", token, `{"model":"claude/sonnet","messages":[{"role":"user","content":"fix it"}]}`); resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	argv, dir := r.lastRun()
	if dir != work || !strings.Contains(strings.Join(argv, " "), "acceptEdits") {
		t.Errorf("ran %v in %s", argv, dir)
	}
	if _, err := os.Stat(work); err != nil {
		t.Errorf("the key's folder was removed: %v", err)
	}
}

func TestAStreamThatFailsBeforeAnyTextKeepsItsStatus(t *testing.T) {
	r := newRig(t, true)
	token := r.key(apikey.New{Name: "grok", Kind: apikey.KindHarness, Harness: "grok"})
	r.answer = func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"error","message":"429 rate limit exceeded"}`), nil, 1
	}
	resp, body := r.post("/v1/chat/completions", token, `{"model":"grok/grok-5","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	if resp.StatusCode != 429 || !strings.Contains(body, "rate_limit_error") || strings.Contains(resp.Header.Get("Content-Type"), "event-stream") {
		t.Errorf("%d %s %s", resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
	if resp, _ := r.post("/v1/chat/completions", token, `{"model":"grok/nope","stream":true,"messages":[{"role":"user","content":"hi"}]}`); resp.StatusCode != 404 {
		t.Errorf("unknown model, streamed: %d", resp.StatusCode)
	}
}
