package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/x/term"

	"github.com/jlengelbrecht/agent-flow-kit/internal/cli"
	"github.com/jlengelbrecht/agent-flow-kit/internal/core"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

const usage = `afk — run the best agent CLI on this machine for the task

  afk [options] [prompt...]          start an interactive session
  afk -p [options] prompt...         print one answer and exit
  afk --explain [options] [prompt]   show the choice and the alternatives
  afk harness [--all] [--json]       the agent CLIs found on this machine

Options:
  -p, --print            one-shot: run headless and print the answer
  --prompt <text>        the prompt (same as the words after --)
  --task <kind>          coding (default), quick, complex, review,
                         architecture, webdev, research, security.
                         Without it the kind is guessed from the prompt.
  --prefer <mode>        balanced (default), cheap (free and local first),
                         best (strongest model for the kind)
  --harness <name>       use this CLI (claude, codex, opencode, grok, agy)
  --model <id>           use this model; without --harness, the CLI that
                         serves it is looked up in the catalog
  --effort <level>       low, medium, high (claude, codex, grok, agy)
  --repo <dir>           project whose .afk/config.json router settings apply
                         (default: the current directory)
  --explain, --dry-run   show the decision and do not start anything
  --json                 machine-readable output for --explain and -p
  --yolo                 let the CLI act without asking (each CLI's own
                         skip-permissions flag); off by default
  --pass <arg>           pass one argument to the CLI unchanged (repeatable)
  -y, --yes              start the router's choice without the route card
  --                     everything after it is the prompt (it may start
                         with a dash)
  --launch-plan --route <json> [--mode interactive|print]
                         print the launch plan for a chosen route as JSON;
                         nothing is started. --route - reads it from stdin
  -h, --help             this help

On the route card: ↵ launch · ↑↓/jk pick · tab effort · e edit the prompt ·
y twice for yolo · ? why · esc cancel.

A prompt that starts with "harness" needs "--" before it.
`

// runGo is afk on the Go engine.
func runGo(args cli.Args) int {
	if args.Help {
		fmt.Print(usage)
		return 0
	}
	if args.Unknown != "" {
		fmt.Fprintf(os.Stderr, "afk: unknown option %s (see afk --help; a prompt that starts with a dash goes in --prompt)\n", args.Unknown)
		return 2
	}
	c := core.New()
	switch {
	case args.LaunchPlan:
		return launchPlanCmd(c, args, os.Stdin, os.Stdout, os.Stderr)
	case args.Print:
		// The one-shot run with failover is still the bash engine's.
		path, err := engine.Locate()
		if err != nil {
			fmt.Fprintln(os.Stderr, "afk: -p still needs the bash engine (agent-flow-kit):", err)
			return 127
		}
		return handOver(path, args.Forward)
	case args.Explain:
		return explainCmd(c, args, os.Stdout, os.Stderr)
	case args.JSON:
		fmt.Fprintln(os.Stderr, "afk: --json goes with --explain or -p")
		return 2
	}
	tty := term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd())
	if !tty {
		return plainRun(c, args, false)
	}
	return interactive(c, args, termWidth())
}

func explainCmd(c *core.Core, args cli.Args, stdout, stderr io.Writer) int {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	ex, err := c.Explain(ctx, args.Flags, args.Prompt)
	if err != nil {
		fmt.Fprintln(stderr, "afk:", err)
		return core.ExitCode(err)
	}
	if args.JSON {
		b, err := json.Marshal(ex)
		if err != nil {
			fmt.Fprintln(stderr, "afk:", err)
			return 1
		}
		fmt.Fprintln(stdout, string(b))
		return 0
	}
	fmt.Fprint(stdout, explainText(ex))
	return 0
}

// explainText is the --explain report for people, as the bash engine
// prints it.
func explainText(ex *engine.Explain) string {
	var b strings.Builder
	guessed := ""
	if ex.TaskGuessed {
		guessed = " (guessed from the prompt)"
	}
	fmt.Fprintf(&b, "task: %s%s  prefer: %s\n", ex.Task, guessed, ex.Prefer)
	r := ex.Choice
	effort := r.Effort
	if effort == "" {
		effort = "default"
	}
	fmt.Fprintf(&b, "choice: %s / %s [effort %s]\n", r.Harness, r.Model, effort)
	pool := r.EntitlementPool
	if pool == "" {
		pool = "-"
	}
	head := ""
	if r.PoolHeadroomPct != nil {
		head = fmt.Sprintf("(%s%% left, %s)", num(r.PoolHeadroomPct), r.PoolState)
	}
	fmt.Fprintf(&b, "  pool: %s %s\n", pool, head)
	score := "-"
	if r.EffectiveScore != nil {
		score = num(r.EffectiveScore)
	}
	basis := ""
	if r.BenchmarkBasis != "" {
		basis = "[" + r.BenchmarkBasis + "]"
	}
	fmt.Fprintf(&b, "  score: %s %s %s\n", score, r.BenchmarkName, basis)
	reason := r.Reason
	if reason == "" {
		reason = "-"
	}
	fmt.Fprintf(&b, "  why: %s\n", reason)
	if len(ex.ByHarness) > 0 {
		b.WriteString("best per installed CLI:\n")
		for _, a := range ex.ByHarness {
			h := (a.Harness + "         ")[:9]
			fmt.Fprintf(&b, "  %s %s — score %s, pool %s %s%% left (%s), %s\n",
				h, a.Model, num(a.EffectiveScore), a.EntitlementPool, num(a.PoolHeadroomPct), a.PoolState, a.CostClass)
		}
	}
	return b.String()
}

func num(v *float64) string {
	if v == nil {
		return "null"
	}
	return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%.4f", *v), "0"), ".")
}

func launchPlanCmd(c *core.Core, args cli.Args, stdin io.Reader, stdout, stderr io.Writer) int {
	raw := args.Route
	if raw == "-" {
		// From stdin, so a gateway address with user info stays off the
		// command line.
		b, err := io.ReadAll(io.LimitReader(stdin, 1<<20))
		if err != nil {
			fmt.Fprintln(stderr, "afk:", err)
			return 1
		}
		raw = string(b)
	}
	var r engine.Route
	if raw == "" || json.Unmarshal([]byte(raw), &r) != nil || r.Harness == "" {
		fmt.Fprintln(stderr, "afk: --launch-plan needs --route with the chosen route JSON")
		return 2
	}
	mode := args.Mode
	if mode == "" {
		mode = "interactive"
	}
	if mode != "interactive" && mode != "print" {
		fmt.Fprintln(stderr, "afk: --mode must be interactive or print")
		return 2
	}
	if mode == "print" && args.Prompt == "" {
		fmt.Fprintln(stderr, "afk: a print plan needs a prompt")
		return 2
	}
	p, err := c.LaunchPlan(context.Background(), r, mode, args.Yolo, args.Pass, args.Prompt)
	var pe *engine.PlanError
	if errors.As(err, &pe) {
		b, _ := json.Marshal(map[string]any{"schema": engine.SchemaLaunchPlan, "ok": false, "error": pe.Reason})
		fmt.Fprintln(stdout, string(b))
		return 4
	}
	if err != nil {
		fmt.Fprintln(stderr, "afk:", err)
		return core.ExitCode(err)
	}
	b, err := json.Marshal(p)
	if err != nil {
		fmt.Fprintln(stderr, "afk:", err)
		return 1
	}
	fmt.Fprintln(stdout, string(b))
	return 0
}
