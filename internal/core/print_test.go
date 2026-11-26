package core

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
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
