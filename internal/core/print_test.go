package core

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/oneshot"
)

// printCore is a Core whose CLIs are never run: Headless answers for them.
func printCore(t *testing.T, answer func(argv []string) ([]byte, []byte, int)) (*Core, *[][]string, string) {
	t.Helper()
	c, _ := testCore(t)
	signals := filepath.Join(c.Home, "signals.json")
	env := map[string]string{"AFK_ROUTER_SIGNALS_FILE": signals, "AFK_SKIP_BENCHMARK_AUTOSYNC": "1"}
	c.Getenv = func(k string) string { return env[k] }
	c.Installed = func(string) bool { return true }
	c.Now = func() time.Time { return time.Unix(1764158400, 0) }
	var ran [][]string
	c.Headless = func(_ context.Context, argv, _ []string, _ string) ([]byte, []byte, int) {
		ran = append(ran, argv)
		return answer(argv)
	}
	return c, &ran, signals
}

func TestPrintFailsOverAndMarksThePool(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	first := ""
	c, ran, signals := printCore(t, func(argv []string) ([]byte, []byte, int) {
		h := filepath.Base(argv[0])
		if first == "" || h == first {
			first = h
			return []byte(`{"type":"result","is_error":true,"result":"429 rate limit exceeded"}`), nil, 1
		}
		return []byte(`{"type":"result","is_error":false,"result":"done"}` + "\n"), nil, 0
	})
	res, err := c.Print(context.Background(), PrintRequest{Prompt: "fix the failing test"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !res.OK || res.Attempts != 2 || res.Output != "done" {
		t.Fatalf("result %+v", res)
	}
	if len(*ran) != 2 || filepath.Base((*ran)[0][0]) == filepath.Base((*ran)[1][0]) {
		t.Fatalf("ran %v", *ran)
	}
	// Each run is the print-mode launch plan's command.
	if !strings.Contains(strings.Join((*ran)[0], " "), "fix the failing test") {
		t.Errorf("argv %v", (*ran)[0])
	}
	b, err := os.ReadFile(signals)
	if err != nil || !strings.Contains(string(b), `"degraded_kind": "quota"`) {
		t.Errorf("signals %s %v", b, err)
	}
}

func TestPrintPinnedReportsTheFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	c, ran, _ := printCore(t, func([]string) ([]byte, []byte, int) {
		return nil, []byte("boom"), 3
	})
	res, err := c.Print(context.Background(), PrintRequest{Prompt: "hi", Flags: engine.RouteFlags{Harness: "codex"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK || res.Attempts != 1 || res.Exit != 3 || res.Error != "boom" || len(*ran) != 1 {
		t.Fatalf("result %+v", res)
	}
}

func TestPrintPinnedRateLimitMarksItsPool(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	c, ran, signals := printCore(t, func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"result","is_error":true,"result":"429 rate limit exceeded"}`), nil, 1
	})
	res, err := c.Print(context.Background(), PrintRequest{Prompt: "hi", Flags: engine.RouteFlags{Harness: "claude", Model: "sonnet"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK || res.Attempts != 1 || len(*ran) != 1 {
		t.Fatalf("result %+v", res)
	}
	b, err := os.ReadFile(signals)
	if err != nil || !strings.Contains(string(b), `"anthropic-max"`) || !strings.Contains(string(b), `"degraded_kind": "quota"`) {
		t.Errorf("signals %s %v", b, err)
	}
}

func TestPrintUsageErrors(t *testing.T) {
	c, ran, _ := printCore(t, nil)
	if _, err := c.Print(context.Background(), PrintRequest{}, nil); ExitCode(err) != 2 {
		t.Errorf("no prompt: %v", err)
	}
	if _, err := c.Print(context.Background(), PrintRequest{Prompt: "x", Flags: engine.RouteFlags{Prefer: "fast"}}, nil); ExitCode(err) != 2 {
		t.Errorf("bad --prefer: %v", err)
	}
	if len(*ran) != 0 {
		t.Error("ran a CLI on a usage error")
	}
}

func TestPrintKeepsClaudesReportedUsage(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	stream, err := os.ReadFile("../oneshot/testdata/claude-stream-ok.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	c, ran, _ := printCore(t, func(argv []string) ([]byte, []byte, int) { return stream, nil, 0 })
	res, err := c.Print(context.Background(), PrintRequest{Prompt: "hi", Flags: engine.RouteFlags{Harness: "claude"}}, nil)
	if err != nil || !res.OK || res.Output != "ok" {
		t.Fatalf("result %+v %v", res, err)
	}
	if got := strings.Join((*ran)[0], " "); !strings.Contains(got, "--output-format stream-json --verbose") {
		t.Errorf("argv %s", got)
	}
	b, err := os.ReadFile(filepath.Join(c.Home, ".config", "afk", "state", "plan-usage.json"))
	if err != nil || !strings.Contains(string(b), `"anthropic-max"`) || !strings.Contains(string(b), `"used_pct": 17`) {
		t.Fatalf("plan usage %s %v", b, err)
	}
}

func TestCappedStreamKeepsTheResult(t *testing.T) {
	status := []byte(`{"type":"assistant","message":"` + strings.Repeat("x", 90) + `"}` + "\n")
	w := capped{max: 1000, keepLines: true}
	for i := 0; i < 50; i++ {
		_, _ = w.Write(status)
	}
	_, _ = w.Write([]byte(`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}` + "\n"))
	// The result arrives split across writes.
	_, _ = w.Write([]byte(`{"type":"result","is_error":false,`))
	_, _ = w.Write([]byte(`"result":"done"}` + "\n"))
	out := w.Output()
	if got, ok := oneshot.Answer(out, nil); !ok || got != "done" {
		t.Fatalf("answer %q %v from\n%s", got, ok, out)
	}
	if !bytes.Contains(out, []byte("rate_limit_event")) {
		t.Error("the usage event past the cap was dropped")
	}

	// Cut short with no result: a failure, never a fragment as the answer.
	w = capped{max: 1000, keepLines: true}
	for i := 0; i < 50; i++ {
		_, _ = w.Write(status)
	}
	if got, ok := oneshot.Answer(w.Output(), nil); ok || !strings.Contains(got, "64 MiB") {
		t.Fatalf("truncated stream: %q %v", got, ok)
	}

	// Plain text is cut as before.
	w = capped{max: 10, keepLines: true}
	_, _ = w.Write([]byte("hello world, this is long"))
	if string(w.Output()) != "hello worl" {
		t.Errorf("text: %q", w.Output())
	}
}

func TestExecHeadlessHandsOverLinesAsTheyArePrinted(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell")
	}
	var lines []string
	stdout, _, exit := execHeadless(context.Background(), []string{"/bin/sh", "-c", `printf 'one\ntwo\n\nlast'`}, nil, "", func(b []byte) {
		lines = append(lines, string(b))
	})
	if exit != 0 || string(stdout) != "one\ntwo\n\nlast" || strings.Join(lines, "|") != "one|two|last" {
		t.Errorf("exit %d stdout %q lines %v", exit, stdout, lines)
	}
}

func TestNoPlanKeepsARunOffEverySignIn(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	c, ran, _ := printCore(t, func([]string) ([]byte, []byte, int) {
		return []byte(`{"type":"result","is_error":false,"result":"done"}`), nil, 0
	})
	var pe *PlanRunsError
	// Routed: every route here is a CLI on its own plan.
	if _, err := c.Print(context.Background(), PrintRequest{Prompt: "hi", Flags: engine.RouteFlags{NoPlan: true}}, nil); !errors.As(err, &pe) {
		t.Errorf("routed: %v", err)
	}
	// Pinned: a named CLI and model run on that CLI's sign-in.
	_, err := c.Print(context.Background(), PrintRequest{Prompt: "hi", Flags: engine.RouteFlags{NoPlan: true, Harness: "grok", Model: "anything"}}, nil)
	if !errors.As(err, &pe) || pe.Harness != "grok" {
		t.Errorf("pinned: %v", err)
	}
	if len(*ran) != 0 {
		t.Errorf("ran %v", *ran)
	}
	// In keeps the engine's stand-ins and moves it to another folder.
	dir := t.TempDir()
	if in := c.In(dir); in.Cwd != dir || in.Headless == nil || in.Home != c.Home {
		t.Errorf("In: %+v", in)
	}
}
