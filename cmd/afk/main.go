// afk is AFK's command: it shows the route card for a task, lets the user
// change the pick, starts the chosen CLI as a foreground child, and prints
// a receipt when the CLI exits. Routing, launch plans, one-shot answers
// (-p) and the benchmark sync run in internal/core, internal/oneshot and
// internal/bench.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/term"

	"github.com/homelab-0/agent-flow-kit/internal/cli"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/gitstat"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/launch"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

func main() { os.Exit(run(os.Args[1:])) }

func run(argv []string) int {
	// Harness manifest overrides (~/.config/afk/harnesses/*.toml).
	if home, err := os.UserHomeDir(); err == nil {
		dir := filepath.Join(config.PathsFor(home, os.Getenv).Dir, "harnesses")
		warns, err := harness.LoadOverrides(dir)
		if err != nil {
			fmt.Fprintln(os.Stderr, "afk:", err)
			return 1
		}
		for _, w := range warns {
			fmt.Fprintln(os.Stderr, "afk: warning:", w)
		}
	}
	// Subcommands the Go front end answers itself, without the engine.
	// A prompt that starts with one of these words needs "--" first.
	if len(argv) > 0 {
		switch argv[0] {
		case "harness", "harnesses":
			return harnessCmd(argv[1:], os.Stdout, os.Stderr)
		case "bench":
			return benchCmd(argv[1:], os.Stdout, os.Stderr)
		case "config":
			return configCmd(argv[1:], os.Stdout, os.Stderr)
		case "trust":
			return trustCmd(argv[1:], os.Stdout, os.Stderr)
		case "pools":
			return poolsCmd(argv[1:], os.Stdout, os.Stderr)
		case "mcp":
			return mcpCmd(argv[1:], os.Stdout, os.Stderr)
		case "skills":
			return skillsCmd(argv[1:], os.Stdout, os.Stderr)
		case "status":
			return statusCmd(argv[1:], os.Stdout, os.Stderr)
		case "version", "--version":
			return versionCmd(argv[1:], os.Stdout, os.Stderr)
		}
	}
	return runGo(cli.Parse(argv))
}

func termWidth() int {
	width, _, err := term.GetSize(os.Stdout.Fd())
	if err != nil || width <= 0 {
		width = 80
	}
	return width
}

func interactive(eng tui.Backend, args cli.Args, width int) int {
	// Below 40 columns, or on a dumb terminal, there is no card and no
	// Bubble Tea program: plain lines, the way the bash afk prints.
	if width < 40 || strings.EqualFold(os.Getenv("TERM"), "dumb") {
		return plainRun(eng, args, true)
	}
	motion := !tui.MotionOff(os.Getenv)
	dark := true
	if os.Getenv("NO_COLOR") == "" {
		dark = lipgloss.HasDarkBackground(os.Stdin, os.Stdout)
	}
	logos, overlay := setupLogos()
	opt := tui.Options{
		Flags: args.Flags, Prompt: args.Prompt, Pass: args.Pass, Yolo: args.Yolo,
		Yes: args.Yes, Width: width, Motion: motion, FPS: tui.FPS(os.Getenv), Dark: dark,
		YoloCheck: func() string { return yoloBlock(eng, args.Flags.Repo) },
		Header:    headerInfo(),
		Logos:     logos,
		// Plain `afk` opens the composer; with a prompt it routes at once.
		Compose: args.Prompt == "" && !args.Yes,
	}
	if c, ok := eng.(*core.Core); ok {
		opt.Panel = newPanelSource(c, args.Flags.Repo)
	}
	if opt.Header != nil {
		opt.Version = opt.Header.Version
	}
	model := tui.New(eng, opt)
	p := tea.NewProgram(tui.WithKittyLogos(tui.WithOverlay(model, overlay), logos), tea.WithFPS(opt.FPS))
	_, err := p.Run()
	model.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "afk:", err)
		return 1
	}
	dec := model.Decision()
	switch {
	case dec.Err != nil:
		return engineFailure(dec.Err)
	case dec.Cancelled:
		return 130
	case !dec.Launch:
		return 1
	}
	theme := tui.NewTheme(dark).WithLogos(logos)
	art := opt.Header != nil && opt.Header.Art
	s := sessionInfo{eng: eng, route: dec.Route, plan: dec.Plan, before: dec.Pools.Headroom(dec.Route.EntitlementPool)}
	return s.run(func(id string) {
		lipgloss.Println(theme.LaunchText(dec.Route, "here", id, dec.Yolo, width))
		if dec.Plan != nil && dec.Plan.ModeNote != "" {
			lipgloss.Println(theme.Dim.Render("  " + dec.Plan.ModeNote))
		}
		lipgloss.Println()
		lipgloss.Println(theme.HandoffText(dec.Route, art, width))
		lipgloss.Println()
		lipgloss.Println(theme.SessionRuleText(dec.Route))
	}, func() {
		lipgloss.Println(theme.EndRuleText())
		lipgloss.Println()
	}, func(receipt tui.Receipt, fill func() tui.Receipt, save func(string) error) {
		rm := tui.NewRating(receipt, fill, save, dark, motion).WithEsc(art, width, nil)
		if _, err := tea.NewProgram(rm).Run(); err != nil {
			fmt.Fprintln(os.Stderr, "afk:", err)
		}
	})
}

// engineFailure prints err and returns its exit code: 2 for a usage
// error (such as yolo in an untrusted directory), 3 for a CLI that is
// not installed, else 4.
func engineFailure(err error) int {
	fmt.Fprintln(os.Stderr, "afk:", strings.TrimSpace(err.Error()))
	switch code := core.ExitCode(err); code {
	case 2, 3:
		return code
	}
	return 4
}

// plainRun is the session without a card: a narrow or dumb terminal, or
// no terminal at all. ask is whether a person is there to rate the run;
// without one, the receipt goes to stderr and nothing reads stdin, so a
// script or a redirected afk never waits.
func plainRun(eng tui.Backend, args cli.Args, ask bool) int {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	ex, err := eng.Explain(ctx, args.Flags, args.Prompt)
	cancel()
	if err != nil {
		return engineFailure(err)
	}
	r := ex.Choice
	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Second)
	plan, err := eng.LaunchPlan(ctx, r, "interactive", ex.Mode, args.Pass, args.Prompt)
	cancel()
	var pe *engine.PlanError
	if errors.As(err, &pe) {
		fmt.Fprintf(os.Stderr, "afk: cannot start %s / %s: %s\n", r.Harness, r.Model, pe.Reason)
		return 4
	}
	if err != nil {
		return engineFailure(err)
	}
	if _, err := launch.BuildEnv(os.Environ(), plan.EnvSet, plan.EnvFrom, plan.EnvUnset); err != nil {
		fmt.Fprintf(os.Stderr, "afk: cannot start %s / %s: %s\n", r.Harness, r.Model, err)
		return 4
	}
	s := sessionInfo{eng: eng, route: r, plan: plan, before: r.PoolHeadroomPct}
	return s.run(func(id string) {
		e := ""
		if r.Effort != "" {
			e = " (" + r.Effort + ")"
		}
		reason := r.Reason
		if len(reason) > 160 {
			reason = reason[:160]
		}
		fmt.Fprintf(os.Stderr, "afk: %s / %s%s — %s (run %s)\n", r.Harness, r.Model, e, reason, id)
		if plan.ModeNote != "" {
			fmt.Fprintln(os.Stderr, "afk: "+plan.ModeNote)
		}
		if plan.ConfigNote != "" {
			fmt.Fprintln(os.Stderr, "afk: "+plan.ConfigNote)
		}
	}, func() {}, func(receipt tui.Receipt, fill func() tui.Receipt, save func(string) error) {
		if !ask {
			fmt.Fprintln(os.Stderr, tui.ReceiptPlain(fill()))
			if err := save(""); err != nil {
				fmt.Fprintln(os.Stderr, "afk: run not saved:", err)
			}
			return
		}
		fmt.Println(tui.ReceiptPlain(fill()))
		if err := save(""); err != nil {
			fmt.Fprintln(os.Stderr, "afk: run not saved:", err)
		}
		fmt.Print(tui.RatingPlain() + " ")
		ans, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		outcome := tui.Ratings[strings.TrimSpace(ans)]
		if err := save(outcome); err != nil {
			fmt.Fprintln(os.Stderr, "afk: run not saved:", err)
		} else if outcome != "" {
			fmt.Println("    Saved.")
		}
	})
}

// sessionInfo is one launch: what to start and what to measure.
type sessionInfo struct {
	eng    tui.Backend
	route  engine.Route
	plan   *engine.LaunchPlan
	before *float64 // pool headroom when the card opened
}

// run starts the CLI, then measures and records the session. The three
// hooks print around it: before (with the run id), after, and the receipt.
func (s sessionInfo) run(before func(id string), after func(), receipt func(tui.Receipt, func() tui.Receipt, func(string) error)) int {
	r, plan := s.route, s.plan
	dir, err := runrec.Dir()
	id := ""
	if err == nil {
		id, err = runrec.Reserve(dir)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "afk: this run will not be saved:", err)
		dir, id = "", runrec.Fallback()
	}
	unreserve := func() {
		if dir != "" {
			_ = os.Remove(filepath.Join(dir, id+".json"))
		}
	}

	env, err := launch.BuildEnv(os.Environ(), plan.EnvSet, plan.EnvFrom, plan.EnvUnset)
	if err != nil {
		unreserve()
		fmt.Fprintln(os.Stderr, "afk: not starting", r.Harness+":", err)
		return 4
	}
	cwd := plan.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	argv0, err := lookArgv0(plan.Argv[0], env)
	if err != nil {
		unreserve()
		fmt.Fprintln(os.Stderr, "afk:", err)
		return 127
	}
	before(id)
	snap := gitstat.Take(cwd)
	pre := s.before
	if pre == nil {
		pre = r.PoolHeadroomPct
	}
	launch.PrepareDirs(plan.EnvSet)
	spec := launch.Spec{Argv: append([]string{argv0}, plan.Argv[1:]...), Env: env, Dir: cwd, TTY: os.Stdin}
	saved, _ := term.GetState(os.Stdin.Fd())
	res, runErr := launch.Run(spec)
	spec.Env, env = nil, nil
	if saved != nil {
		_ = term.Restore(os.Stdin.Fd(), saved)
	}
	if runErr != nil {
		unreserve()
		fmt.Fprintln(os.Stderr, "afk:", runErr)
		return 127
	}
	after()

	rec := runrec.Record{
		ID: id, Where: "here", Route: r.Redacted(), Exit: res.ExitCode,
		StartedAt: runrec.Stamp(res.Started), EndedAt: runrec.Stamp(res.Ended),
		DurationS:  int64(res.Duration().Round(time.Second) / time.Second),
		PoolBefore: tui.PctInt(pre),
	}
	rc := tui.Receipt{Route: r, ExitCode: res.ExitCode, Signal: res.Signal, Duration: res.Duration(), PoolBefore: pre, InRepo: snap.OK()}
	fill := func() tui.Receipt {
		out := rc
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if pools, err := s.eng.Pools(ctx); err == nil {
			out.PoolAfter = pools.Headroom(r.EntitlementPool)
		}
		ch := snap.Since()
		out.Files, out.Commits = ch.Files, ch.Commits
		rec.PoolAfter, rec.FilesChanged, rec.Commits = tui.PctInt(out.PoolAfter), ch.Files, ch.Commits
		return out
	}
	save := func(outcome string) error {
		if dir == "" {
			return errors.New("no place for run records")
		}
		rec.Outcome = nil
		if outcome != "" {
			o := outcome
			rec.Outcome = &o
		}
		_, err := runrec.Write(dir, rec)
		return err
	}
	receipt(rc, fill, save)
	return res.ExitCode
}

// lookArgv0 resolves a bare command name on the child's PATH; the engine
// normally gives an absolute path already.
func lookArgv0(name string, env []string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			for _, d := range filepath.SplitList(v) {
				// Never the current directory: see harness.Locate.
				if !filepath.IsAbs(d) {
					continue
				}
				p := filepath.Join(d, name)
				if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
					return p, nil
				}
			}
		}
	}
	return "", fmt.Errorf("cannot find %s on PATH", name)
}

// yoloBlock is why yolo can't be turned on in this directory, or "".
func yoloBlock(eng tui.Backend, repo string) string {
	c, ok := eng.(*core.Core)
	if !ok {
		return ""
	}
	if repo == "" {
		repo = c.Cwd
	}
	s, err := c.LoadSettings(repo)
	if err != nil {
		return err.Error()
	}
	if err := config.CheckYolo(s, c.Home, c.Cwd); err != nil {
		return err.Error()
	}
	return ""
}
