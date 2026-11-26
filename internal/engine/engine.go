// Package engine talks to the bash engine (bin/agent-flow-kit) through its
// JSON contract: the routing decision (--explain --json), the launch plan
// (--launch-plan --json) and the pool usage (factory pools --json). Every
// payload carries a schema, and a version this package does not know is
// refused rather than guessed at.
package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Schemas this front end understands.
const (
	SchemaExplain    = "afk-route-explain/1"
	SchemaLaunchPlan = "afk-launch-plan/1"
	SchemaPools      = "afk-router-pools/3"
)

// EngineName is the engine's file name next to the front end or on PATH.
const EngineName = "agent-flow-kit"

// Locate finds the engine: $AFK_ENGINE, then agent-flow-kit next to this
// binary (as invoked, then with symlinks resolved), then PATH.
func Locate() (string, error) {
	if p := os.Getenv("AFK_ENGINE"); p != "" {
		// Return the path that was checked: a bare name would send
		// exec to PATH, which may find another program.
		abs, err := filepath.Abs(p)
		if err == nil && isExec(abs) {
			return abs, nil
		}
		return "", fmt.Errorf("AFK_ENGINE=%s is not an executable file", p)
	}
	// Next to this binary: as invoked first, then where it really lives.
	var dirs []string
	if a0 := os.Args[0]; strings.Contains(a0, "/") {
		if abs, err := filepath.Abs(a0); err == nil {
			dirs = append(dirs, filepath.Dir(abs))
		}
	}
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs, filepath.Dir(exe))
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			dirs = append(dirs, filepath.Dir(real))
		}
	}
	for _, d := range dirs {
		if p := filepath.Join(d, EngineName); isExec(p) {
			return p, nil
		}
	}
	if p, err := exec.LookPath(EngineName); err == nil {
		return p, nil
	}
	return "", errors.New("cannot find agent-flow-kit: set AFK_ENGINE, or install it next to afk or on PATH")
}

func isExec(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

// Engine runs engine commands.
type Engine struct {
	Path string
	// Env, when non-nil, replaces the environment of engine calls.
	Env []string
}

// ExitError is a failed engine call: its exit status and what it said.
type ExitError struct {
	Code   int
	Stderr string
	Stdout []byte
}

func (e *ExitError) Error() string {
	msg := strings.TrimSpace(e.Stderr)
	if msg == "" {
		msg = fmt.Sprintf("the engine exited %d", e.Code)
	}
	return msg
}

// TimeoutError is an engine call that did not answer in time; the call
// and everything it started are killed.
type TimeoutError struct{ Call string }

func (e *TimeoutError) Error() string {
	return fmt.Sprintf("the engine did not answer %s in time; it was stopped", e.Call)
}

// waitDelay bounds how long a killed engine's output pipes may stay open
// (a grandchild holding them) before the call returns anyway.
const waitDelay = 2 * time.Second

// CallTimeout is the longest any engine call may run, whatever the caller
// asked for. A shorter deadline from the caller still applies.
var CallTimeout = 2 * time.Minute

func (e *Engine) run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, CallTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, e.Path, args...)
	cmd.Env = e.Env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	ownGroup(cmd)
	cmd.WaitDelay = waitDelay
	err := cmd.Run()
	if ctx.Err() != nil {
		call := "the call"
		if len(args) > 1 {
			call = strings.TrimLeft(args[1], "-")
		}
		return nil, &TimeoutError{Call: call}
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return out.Bytes(), &ExitError{Code: ee.ExitCode(), Stderr: errb.String(), Stdout: out.Bytes()}
		}
		return nil, err
	}
	return out.Bytes(), nil
}

// RouteFlags are the routing options the user gave.
type RouteFlags struct {
	Task, Prefer, Harness, Model, Effort, Repo string
}

func (f RouteFlags) args() []string {
	var a []string
	add := func(k, v string) {
		if v != "" {
			a = append(a, k, v)
		}
	}
	add("--task", f.Task)
	add("--prefer", f.Prefer)
	add("--harness", f.Harness)
	add("--model", f.Model)
	add("--effort", f.Effort)
	add("--repo", f.Repo)
	return a
}

// ExplainArgs is the engine command line for a routing decision.
func ExplainArgs(f RouteFlags, prompt string) []string {
	a := append([]string{"agent", "--explain", "--json"}, f.args()...)
	return append(a, "--", prompt)
}

// Explain asks the engine for the routing decision and the best route per
// installed CLI.
func (e *Engine) Explain(ctx context.Context, f RouteFlags, prompt string) (*Explain, error) {
	out, err := e.run(ctx, nil, ExplainArgs(f, prompt)...)
	if err != nil {
		return nil, err
	}
	return ParseExplain(out)
}

// LaunchArgs is the engine command line for a launch plan. The route goes
// on stdin (--route -), never on the command line, where any process can
// read it.
func LaunchArgs(route Route, mode string, yolo bool, pass []string, prompt string) (args []string, stdin []byte, err error) {
	rj, err := json.Marshal(route)
	if err != nil {
		return nil, nil, err
	}
	a := []string{"agent", "--launch-plan", "--json", "--route", "-", "--mode", mode}
	if yolo {
		a = append(a, "--yolo")
	}
	for _, p := range pass {
		a = append(a, "--pass", p)
	}
	return append(a, "--", prompt), rj, nil
}

// LaunchPlan asks the engine how to start a route. A route that cannot start
// returns a *PlanError with the engine's reason.
func (e *Engine) LaunchPlan(ctx context.Context, route Route, mode string, yolo bool, pass []string, prompt string) (*LaunchPlan, error) {
	args, stdin, err := LaunchArgs(route, mode, yolo, pass, prompt)
	if err != nil {
		return nil, err
	}
	out, err := e.run(ctx, stdin, args...)
	if err != nil {
		var ee *ExitError
		if errors.As(err, &ee) && ee.Code == 4 {
			if p, perr := ParseLaunchPlan(ee.Stdout); perr == nil && !p.OK {
				return nil, &PlanError{Reason: p.Error}
			}
		}
		return nil, err
	}
	p, err := ParseLaunchPlan(out)
	if err != nil {
		return nil, err
	}
	if !p.OK {
		return nil, &PlanError{Reason: p.Error}
	}
	return p, nil
}

// PlanError is a route the engine will not start, with its reason.
type PlanError struct{ Reason string }

func (e *PlanError) Error() string { return e.Reason }

// Pools reads the plan pool usage. It is display data: a failure or an
// unknown schema leaves the pools unknown, it never stops a launch.
func (e *Engine) Pools(ctx context.Context) (*Pools, error) {
	out, err := e.run(ctx, nil, "factory", "pools", "--json")
	if err != nil {
		return nil, err
	}
	return ParsePools(out)
}

// SchemaError is a payload whose schema this front end does not know.
type SchemaError struct{ Want, Got string }

func (e *SchemaError) Error() string {
	if e.Got == "" {
		return fmt.Sprintf("the engine sent no schema (this afk reads %s); update agent-flow-kit", e.Want)
	}
	return fmt.Sprintf("the engine speaks %s and this afk reads %s; update afk and agent-flow-kit together", e.Got, e.Want)
}

func checkSchema(b []byte, want string) error {
	var head struct {
		Schema string `json:"schema"`
	}
	if err := json.Unmarshal(b, &head); err != nil {
		return fmt.Errorf("the engine sent something that is not JSON: %w", err)
	}
	if head.Schema != want {
		return &SchemaError{Want: want, Got: head.Schema}
	}
	return nil
}
