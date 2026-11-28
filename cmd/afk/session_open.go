package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/term"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/launch"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// canOpen says why the last run's session can't be reopened in its CLI,
// or "" when it can.
func (r *ranHere) canOpen() string {
	if r == nil {
		return "nothing to open yet: run a task first"
	}
	name := r.route.Harness
	a, ok := harness.Lookup(name)
	switch {
	case !ok:
		return "nothing to open: the last run has no CLI"
	case r.route.IsGateway() || r.route.IsLocal():
		return "a gateway or local run can't be reopened from AFK yet"
	case r.rec.Session == "":
		return name + " didn't report a session id for the last run, so AFK can't reopen it"
	case a.Manifest.ResumeArgv(r.rec.Session) == nil:
		return "AFK doesn't know how to reopen a " + name + " session"
	}
	return ""
}

// openSession gives the terminal to the CLI of the last run, reopened on
// that run's session, and takes it back when the CLI exits. The CLI runs
// with the environment a normal launch of that route gets. It returns the
// CLI's exit code.
func openSession(eng tui.Backend, he harness.Env, r *ranHere, theme tui.Theme) int {
	a, _ := harness.Lookup(r.route.Harness)
	bin := harness.Locate(he, a)
	if bin == "" {
		fmt.Fprintln(os.Stderr, "afk:", r.route.Harness, "is not installed any more")
		return 127
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	plan, err := eng.LaunchPlan(ctx, r.route, "interactive", "", nil, "")
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, "afk: not opening", r.route.Harness+":", err)
		return 4
	}
	env, err := launch.BuildEnv(os.Environ(), plan.EnvSet, plan.EnvFrom, plan.EnvUnset)
	if err != nil {
		fmt.Fprintln(os.Stderr, "afk: not opening", r.route.Harness+":", err)
		return 4
	}
	cwd := plan.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	lipgloss.Println(theme.NoteText("opening " + r.route.Harness + " session " + r.rec.Session + " · exit the CLI to come back to AFK"))
	lipgloss.Println(theme.SessionRuleText(r.route))
	spec := launch.Spec{Argv: append([]string{bin}, a.Manifest.ResumeArgv(r.rec.Session)...), Env: env, Dir: cwd, TTY: os.Stdin}
	saved, _ := term.GetState(os.Stdin.Fd())
	res, runErr := launch.Run(spec)
	spec.Env, env = nil, nil
	if saved != nil {
		_ = term.Restore(os.Stdin.Fd(), saved)
	}
	if runErr != nil {
		fmt.Fprintln(os.Stderr, "afk:", runErr)
		return 127
	}
	lipgloss.Println(theme.EndRuleText())
	lipgloss.Println()
	return res.ExitCode
}
