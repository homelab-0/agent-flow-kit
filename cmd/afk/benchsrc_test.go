package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBenchSourceCommands(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("AFK_CONFIG", "")
	t.Setenv("AFK_BENCHMARK_FEED_DIR", "")
	t.Setenv("EVALS_KEY", "secret-value-never-written")
	t.Chdir(t.TempDir())
	run := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		code := benchCmd(args, &out, &errb)
		return code, out.String(), errb.String()
	}
	board := filepath.Join(home, "board.csv")
	if err := os.WriteFile(board, []byte("model,score\nClaude 5.5 Opus,91\nGrok 4.7,88\nSome Old Model,40\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errs := run("source", "add", "my-evals", board, "review,security", "--name", "My evals", "--key", "env:EVALS_KEY", "--key-header", "x-key")
	if code != 0 {
		t.Fatalf("add: %d %s", code, errs)
	}
	for _, want := range []string{"3 models listed", "model:  model", "score:  score", "matched 2 of AFK's models", "claude-opus-native", "grok-4.7-native", "Saved my-evals"} {
		if !strings.Contains(out, want) {
			t.Errorf("add output missing %q:\n%s", want, out)
		}
	}
	cfg, err := os.ReadFile(filepath.Join(home, ".config", "afk", "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	c := string(cfg)
	for _, want := range []string{"[bench.custom.my-evals]", `file = "` + board + `"`, `tasks = ["coding_review", "security"]`, `model = "model"`, `key = "env:EVALS_KEY"`} {
		if !strings.Contains(c, want) {
			t.Errorf("config missing %q:\n%s", want, c)
		}
	}
	if strings.Contains(c, "secret-value") {
		t.Fatal("the key's value was written to config.toml")
	}

	// A source AFK can't read is not saved.
	if code, _, errs := run("source", "add", "broken", filepath.Join(home, "nope.json")); code == 0 || !strings.Contains(errs, "nothing was saved") {
		t.Errorf("unreadable add: %d %s", code, errs)
	}
	if code, _, errs := run("source", "add", "swebench", board); code == 0 || !strings.Contains(errs, "already a source") {
		t.Errorf("a built-in id: %d %s", code, errs)
	}

	code, out, _ = run("source", "list")
	if code != 0 || !strings.Contains(out, "my-evals") || !strings.Contains(out, "swebench") || !strings.Contains(out, "off  artificialanalysis") {
		t.Errorf("list: %s", out)
	}
	if code, out, errs := run("source", "test", "my-evals"); code != 0 || !strings.Contains(out, "matched 2") {
		t.Errorf("test: %d %s %s", code, out, errs)
	}
	if code, out, errs := run("weight", "my-evals", "2", "review"); code != 0 || !strings.Contains(out, "weighs 2 for coding_review") {
		t.Errorf("weight: %d %s %s", code, out, errs)
	}
	if code, _, errs := run("weight", "lmarena", "0.5"); code != 0 {
		t.Errorf("lmarena weight: %s", errs)
	}
	if code, _, errs := run("source", "off", "swebench"); code != 0 {
		t.Errorf("off: %s", errs)
	}
	cfg, _ = os.ReadFile(filepath.Join(home, ".config", "afk", "config.toml"))
	for _, want := range []string{"[bench.weights.coding_review]", "my-evals = 2", "lmarena = 0.5", "swebench"} {
		if !strings.Contains(string(cfg), want) {
			t.Errorf("config missing %q:\n%s", want, cfg)
		}
	}
	if code, _, errs := run("source", "rm", "swebench"); code == 0 || !strings.Contains(errs, "built in") {
		t.Errorf("rm built-in: %d %s", code, errs)
	}
	if code, _, errs := run("source", "rm", "my-evals"); code != 0 {
		t.Errorf("rm: %s", errs)
	}
	cfg, _ = os.ReadFile(filepath.Join(home, ".config", "afk", "config.toml"))
	if strings.Contains(string(cfg), "bench.custom.my-evals") {
		t.Errorf("rm left it:\n%s", cfg)
	}
}

func TestParseTasks(t *testing.T) {
	got, err := parseTasks("complex, review,coding_standard,complex")
	if err != nil || strings.Join(got, ",") != "coding_complex,coding_review,coding_standard" {
		t.Errorf("%v %v", got, err)
	}
	if _, err := parseTasks("cooking"); err == nil {
		t.Error("unknown task accepted")
	}
}
