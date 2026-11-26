package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/gitstat"
	"github.com/jlengelbrecht/agent-flow-kit/internal/launch"
	"github.com/jlengelbrecht/agent-flow-kit/internal/oneshot"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

// PrintRequest is one afk -p run.
type PrintRequest struct {
	Flags  engine.RouteFlags // Flags.Perm is --mode or --yolo
	Prompt string
	Pass   []string
}

// Headless runs a command with no terminal and returns what it printed.
type Headless func(ctx context.Context, argv, env []string, dir string) (stdout, stderr []byte, exit int)

// Print routes the prompt and runs the chosen CLI headless, with failover
// to the next route on a failure (see package oneshot). note gets the
// lines for the person (failover notices). A usage, install or routing
// problem before the first run is returned as an error.
func (c *Core) Print(ctx context.Context, req PrintRequest, note func(string)) (oneshot.Result, error) {
	if req.Prompt == "" {
		return oneshot.Result{}, &UsageError{"-p needs a prompt"}
	}
	d, err := c.decide(ctx, req.Flags, req.Prompt)
	if err != nil {
		return oneshot.Result{}, err
	}
	first, err := toEngineRoute(d.choice)
	if err != nil {
		return oneshot.Result{}, err
	}
	signals := router.ProbeEnv{Home: c.Home, Getenv: c.getenv}.SignalsPath()
	deps := oneshot.Deps{
		Run: func(ctx context.Context, r engine.Route, mode string) oneshot.Output {
			out := c.runHeadless(ctx, r, mode, req)
			c.notePlanUsage(r, out.Stdout)
			return out
		},
		Next: func(ctx context.Context, only []string, pool string) (engine.Route, bool) {
			// Read the pools again: the failure just recorded is in them.
			st, err := c.load(ctx, d.repo)
			if err != nil {
				return engine.Route{}, false
			}
			r, ok, err := st.route(d.task, d.prefer, only, pool)
			if err != nil || !ok {
				return engine.Route{}, false
			}
			er, err := toEngineRoute(r)
			return er, err == nil
		},
		Mark: func(kind oneshot.Kind, pool, model, reason string) {
			switch kind {
			case oneshot.KindModel:
				_ = router.MarkModelUnavailable(signals, model, reason, c.now())
			case oneshot.KindPool:
				_ = router.MarkPoolDegraded(signals, pool, reason, c.now())
			}
		},
		Note: note,
	}
	// What the working copy looked like before the first attempt, so a
	// failover can say when a failed route left edits behind.
	if snap := gitstat.Take(c.cwd()); snap.OK() {
		deps.Changed = func() *int { return snap.Since().Files }
	}
	pinned := req.Flags.Harness != "" || req.Flags.Model != ""
	// The pinned route's JSON keeps entitlement_pool null; its failures
	// are still recorded against the pool that serves it.
	firstPool := ""
	if first.EntitlementPool == "" {
		firstPool = d.st.r.PoolFor(first.Harness, first.Model)
	}
	return oneshot.Do(ctx, oneshot.Request{First: first, Pinned: pinned, Harnesses: d.list, Effort: req.Flags.Effort, FirstPool: firstPool, Mode: d.mode, Failover: d.st.settings.Failover}, deps), nil
}

func toEngineRoute(v any) (engine.Route, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return engine.Route{}, err
	}
	var r engine.Route
	if err := json.Unmarshal(b, &r); err != nil {
		return engine.Route{}, err
	}
	return r, nil
}

// runHeadless plans one print-mode launch and runs it with stdin closed.
func (c *Core) runHeadless(ctx context.Context, r engine.Route, mode string, req PrintRequest) oneshot.Output {
	plan, err := c.LaunchPlan(ctx, r, "print", mode, req.Pass, req.Prompt)
	if err != nil {
		reason := err.Error()
		var pe *engine.PlanError
		if errors.As(err, &pe) {
			reason = pe.Reason
		}
		return oneshot.Output{Exit: 127, LaunchError: fmt.Sprintf("cannot launch %s / %s here: %s", r.Harness, r.Model, reason)}
	}
	answerFile := ""
	var ans struct {
		Format string `json:"format"`
		File   string `json:"file"`
	}
	if json.Unmarshal(plan.Answer, &ans) == nil && ans.Format == "text-file" {
		answerFile = ans.File
	}
	defer func() {
		if answerFile != "" {
			_ = os.Remove(answerFile)
		}
	}()
	env, err := launch.BuildEnv(c.environ(), plan.EnvSet, plan.EnvFrom, plan.EnvUnset)
	if err != nil {
		// The error names the variable, never its value.
		return oneshot.Output{Exit: 126, Stderr: []byte("the gateway key variable is empty or not allowed: " + err.Error())}
	}
	launch.PrepareDirs(plan.EnvSet)
	run := c.Headless
	if run == nil {
		run = execHeadless
	}
	stdout, stderr, exit := run(ctx, plan.Argv, env, plan.Cwd)
	out := oneshot.Output{Stdout: stdout, Stderr: stderr, Exit: exit, Mode: plan.Mode, ModeNote: plan.ModeNote, ConfigNote: plan.ConfigNote}
	if answerFile != "" {
		if b, err := os.ReadFile(answerFile); err == nil {
			out.Answer = b
		}
	}
	return out
}

func (c *Core) environ() []string {
	if c.Environ != nil {
		return c.Environ()
	}
	return os.Environ()
}

// Most a headless run's output is kept: the answer in full up to 64 MiB,
// and the start of stderr (only its first lines are ever shown).
const (
	maxStdout = 64 << 20
	maxStderr = 64 << 10
)

// execHeadless runs argv with stdin on /dev/null and its output captured.
// Cancelling ctx (Ctrl-C) interrupts the CLI and waits a little for it.
func execHeadless(ctx context.Context, argv, env []string, dir string) ([]byte, []byte, int) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env, cmd.Dir = env, dir
	var stdout, stderr capped
	stdout.max, stderr.max = maxStdout, maxStderr
	stdout.keepLines = true
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if err == nil {
		return stdout.Output(), stderr.Bytes(), 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code := ee.ExitCode()
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			code = 128 + int(ws.Signal())
		}
		if code <= 0 {
			code = 1
		}
		return stdout.Output(), stderr.Bytes(), code
	}
	// It never started.
	stderr.Write([]byte(err.Error()))
	return stdout.Output(), stderr.Bytes(), 127
}

// capped keeps the first max bytes written to it and drops the rest.
//
// For stdout (keepLines) it also keeps, past the cap, the last result
// document and the last rate_limit_event of a JSON stream (claude's
// stream-json), so a long run's status events can't push its answer out.
// A JSON stream cut short with no result kept ends in an error document,
// so the run is not taken as having answered with a fragment.
type capped struct {
	bytes.Buffer
	max       int
	keepLines bool
	dropped   bool
	line      []byte // the line being written, once past the cap
	skipping  bool   // the current line is too long to keep
	result    []byte
	usage     []byte
}

func (w *capped) Write(p []byte) (int, error) {
	n := len(p)
	if !w.dropped {
		room := w.max - w.Len()
		if len(p) <= room {
			w.Buffer.Write(p)
			return n, nil
		}
		w.Buffer.Write(p[:max(room, 0)])
		p = p[max(room, 0):]
		w.dropped = true
		if !w.keepLines {
			return n, nil
		}
		// Finish the line the cap cut, without keeping it.
		w.skipping = true
	}
	if !w.keepLines {
		return n, nil
	}
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		chunk := p
		if i >= 0 {
			chunk = p[:i]
		}
		if !w.skipping {
			if len(w.line)+len(chunk) > keptLineMax {
				w.line, w.skipping = nil, true
			} else {
				w.line = append(w.line, chunk...)
			}
		}
		if i < 0 {
			break
		}
		if !w.skipping {
			w.keep(w.line)
		}
		w.line, w.skipping = nil, false
		p = p[i+1:]
	}
	return n, nil
}

// keptLineMax is the longest line kept past the cap.
const keptLineMax = 4 << 20

func (w *capped) keep(line []byte) {
	switch {
	case bytes.Contains(line, []byte(`"type":"result"`)):
		w.result = append([]byte(nil), line...)
	case bytes.Contains(line, []byte(`"rate_limit_event"`)):
		w.usage = append([]byte(nil), line...)
	}
}

// Output is what was kept: everything, or the start up to its last whole
// line plus the documents kept past the cap.
func (w *capped) Output() []byte {
	if !w.dropped || !w.keepLines {
		return w.Bytes()
	}
	if len(w.line) > 0 && !w.skipping {
		w.keep(w.line) // a last line with no newline
		w.line = nil
	}
	b := w.Bytes()
	head := b
	if i := bytes.LastIndexByte(b, '\n'); i >= 0 {
		head = b[:i+1]
	}
	stream := bytes.HasPrefix(bytes.TrimSpace(b), []byte("{"))
	if !stream {
		return b
	}
	out := append([]byte(nil), head...)
	for _, d := range [][]byte{w.usage, w.result} {
		if len(d) > 0 {
			out = append(append(out, d...), '\n')
		}
	}
	if len(w.result) == 0 {
		out = append(out, []byte(`{"type":"result","is_error":true,"result":"afk: the CLI's output passed 64 MiB before its answer, which was lost"}`+"\n")...)
	}
	return out
}

// notePlanUsage keeps the plan usage a run's own output reported, so the
// next route card shows a measured figure. Only Claude on its plan login
// reports it (a gateway route's limits aren't the plan's).
func (c *Core) notePlanUsage(r engine.Route, stdout []byte) {
	if r.Harness != "claude" || strings.HasSuffix(r.LaunchClass, "-gateway") {
		return
	}
	pool := r.EntitlementPool
	if pool == "" {
		pool = "anthropic-max"
	}
	if pool != "anthropic-max" {
		return
	}
	u, ok := router.ParseClaudeUsage(stdout, c.now())
	if !ok {
		return
	}
	_ = router.RecordPlanUsage(router.ProbeEnv{Home: c.Home, Getenv: c.getenv}.UsagePath(), pool, u)
}
