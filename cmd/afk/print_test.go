package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/oneshot"
)

func TestPrintResult(t *testing.T) {
	ok := oneshot.Result{OK: true, Route: engine.Route{Harness: "claude", Model: "sonnet"}, Attempts: 2, Output: "hi", Tried: []string{"codex/sol", "claude/sonnet"}}
	failed := oneshot.Result{Tried: []string{"claude/sonnet", "codex/sol"}, Exit: 1, Error: "boom", Attempts: 2}
	noOther := failed
	noOther.NoOther = true
	cases := []struct {
		name         string
		res          oneshot.Result
		json         bool
		code         int
		stdout, errs string
	}{
		{"answer", ok, false, 0, "hi\n", ""},
		{"answer json", ok, true, 0, `{"ok":true,"harness":"claude","model":"sonnet","effort":null,"attempts":2,"output":"hi"}` + "\n", ""},
		{"failed", failed, false, 5, "", "afk: claude/sonnet, codex/sol failed (exit 1): boom\n"},
		{"failed json", failed, true, 5, `{"ok":false,"tried":"claude/sonnet, codex/sol","exit":1,"error":"boom"}` + "\n", ""},
		{"no other", noOther, false, 5, "", "afk: claude/sonnet, codex/sol failed and no other model is usable: boom\n"},
		{"interrupted", oneshot.Result{Interrupted: true}, false, 130, "", "afk: interrupted\n"},
	}
	for _, tc := range cases {
		var out, errb bytes.Buffer
		if code := printResult(tc.res, tc.json, &out, &errb); code != tc.code || out.String() != tc.stdout || errb.String() != tc.errs {
			t.Errorf("%s: %d %q %q", tc.name, code, out.String(), errb.String())
		}
	}
}

func TestBenchCommandLine(t *testing.T) {
	var out, errb bytes.Buffer
	if benchCmd(nil, &out, &errb) != 0 || !strings.Contains(out.String(), "afk bench sync") {
		t.Errorf("help: %q", out.String())
	}
	if benchCmd([]string{"pull"}, &out, &errb) != 2 || benchCmd([]string{"sync", "--force"}, &out, &errb) != 2 {
		t.Error("unknown words should be usage errors")
	}
}
