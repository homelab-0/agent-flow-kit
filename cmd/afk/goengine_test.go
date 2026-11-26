package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/jlengelbrecht/agent-flow-kit/internal/cli"
	"github.com/jlengelbrecht/agent-flow-kit/internal/core"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

func f(v float64) *float64 { return &v }

func TestExplainTextMatchesTheBashLayout(t *testing.T) {
	ex := &engine.Explain{
		Task: "coding", TaskGuessed: true, Prefer: "balanced",
		Choice: engine.Route{
			Harness: "claude", Model: "sonnet", Effort: "medium", EntitlementPool: "anthropic-max",
			PoolHeadroomPct: f(98), PoolState: "available", EffectiveScore: f(98.41),
			BenchmarkName: "LMArena", BenchmarkBasis: "estimate", Reason: "because",
		},
		ByHarness: []engine.Route{{Harness: "codex", Model: "gpt-6.1-sol", EffectiveScore: f(95.77),
			EntitlementPool: "openai-plus", PoolHeadroomPct: f(86), PoolState: "available", CostClass: "subscription"}},
	}
	want := "task: coding (guessed from the prompt)  prefer: balanced\n" +
		"choice: claude / sonnet [effort medium]\n" +
		"  pool: anthropic-max (98% left, available)\n" +
		"  score: 98.41 LMArena [estimate]\n" +
		"  why: because\n" +
		"best per installed CLI:\n" +
		"  codex     gpt-6.1-sol — score 95.77, pool openai-plus 86% left (available), subscription\n"
	if got := explainText(ex); got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestLaunchPlanCmdRefusals(t *testing.T) {
	c := &core.Core{Getenv: func(string) string { return "" }}
	var out, errb bytes.Buffer
	if code := launchPlanCmd(c, cli.Args{LaunchPlan: true}, strings.NewReader(""), &out, &errb); code != 2 {
		t.Fatalf("no route: %d", code)
	}
	errb.Reset()
	args := cli.Args{LaunchPlan: true, Route: "-", Mode: "print"}
	if code := launchPlanCmd(c, args, strings.NewReader(`{"harness":"claude"}`), &out, &errb); code != 2 || !strings.Contains(errb.String(), "needs a prompt") {
		t.Fatalf("print without prompt: %d %q", code, errb.String())
	}
	out.Reset()
	args = cli.Args{LaunchPlan: true, Route: `{"harness":"pi","entitlement_pool":"openai-plus"}`}
	if code := launchPlanCmd(c, args, nil, &out, &errb); code != 4 || !strings.Contains(out.String(), `"ok":false`) {
		t.Fatalf("pi: %d %q", code, out.String())
	}
}
