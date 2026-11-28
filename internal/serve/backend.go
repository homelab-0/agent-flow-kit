package serve

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/oneshot"
	"github.com/homelab-0/agent-flow-kit/internal/router"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
)

// Model is one model name a key can ask for.
type Model struct {
	ID    string
	Owner string
}

// Call is one request to run.
type Call struct {
	Key apikey.Key
	// Model is the model name the caller sent.
	Model  string
	Effort string
	Prompt string
	// Delta, when set, is given the answer's text as it is written.
	Delta func(string)
}

// Outcome is how a call ended.
type Outcome struct {
	OK   bool
	Text string
	// Streamed says Delta was given the answer as it was written; Text is
	// then what the CLI gave as its final answer, which Delta already
	// covered.
	Streamed bool
	// Route is the CLI and model that answered.
	Route engine.Route
	// Usage is what the CLI reported, nil when it reported none.
	Usage *Usage
	Run   string // the run record's id

	// A failure: the HTTP status, the kind of error and what to say.
	Status     int
	Kind       string
	Error      string
	RetryAfter time.Duration
}

// The kinds of failure.
const (
	KindInvalid    = "invalid_request"
	KindNotFound   = "not_found"
	KindPermission = "permission"
	KindRateLimit  = "rate_limit"
	KindOverloaded = "overloaded"
	KindUpstream   = "api_error"
	KindTooLarge   = "request_too_large"
	KindAuth       = "authentication"
)

func failure(status int, kind, format string, a ...any) Outcome {
	return Outcome{Status: status, Kind: kind, Error: fmt.Sprintf(format, a...)}
}

// Backend is what answers a call.
type Backend interface {
	// Models lists the model names the key can ask for.
	Models(ctx context.Context, k apikey.Key) ([]Model, error)
	// Run answers one call.
	Run(ctx context.Context, c Call) Outcome
}

// CoreBackend answers calls with AFK's own engine: a router key's call is
// routed the way afk -p routes a prompt, a harness key's call runs the
// model it names on that one CLI, and either way the CLI runs headless.
type CoreBackend struct {
	Core *core.Core
	// RunsDir is where run records go ("" keeps none).
	RunsDir string
	// TempDir is where the throwaway folders are made ("" is the
	// system's).
	TempDir string
	// Timeout ends a run that takes longer (0: DefaultTimeout).
	Timeout time.Duration
}

// DefaultTimeout is the longest a served run may take.
const DefaultTimeout = 30 * time.Minute

// RouterModels are the names a router key answers to.
func RouterModels() []string {
	out := []string{"afk/auto"}
	for _, t := range router.Tasks {
		out = append(out, "afk/"+t)
	}
	return out
}

var modelNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,127}$`)

// Models lists what the key reaches. For a harness key these are the
// models that CLI reported for this account, never a catalog's guess: a
// CLI that reports no list has only the key's own model list, if any.
func (b *CoreBackend) Models(ctx context.Context, k apikey.Key) ([]Model, error) {
	if k.Kind == apikey.KindRouter {
		var out []Model
		for _, id := range RouterModels() {
			out = append(out, Model{ID: id, Owner: "afk"})
		}
		return out, nil
	}
	st, err := b.harnessState(ctx, k.Harness)
	if err != nil {
		return nil, err
	}
	names := st.Models
	if len(k.Models) > 0 {
		names = allowed(k.Models, st)
	}
	var out []Model
	if _, ok := defaultModel(k, st); ok {
		out = append(out, Model{ID: k.Harness + "/default", Owner: k.Harness})
	}
	seen := map[string]bool{}
	for _, m := range names {
		if !seen[m] && modelNameRE.MatchString(m) {
			seen[m] = true
			out = append(out, Model{ID: k.Harness + "/" + m, Owner: k.Harness})
		}
	}
	return out, nil
}

// allowed are the key's models, less any the CLI's own list says this
// account doesn't have.
func allowed(keyModels []string, st router.HarnessState) []string {
	if !st.ModelsKnown {
		return keyModels
	}
	var out []string
	for _, m := range keyModels {
		if contains(st.Models, m) {
			out = append(out, m)
		}
	}
	return out
}

// defaultModel is what "default" means for a harness key: the CLI's own
// default model when it reported one the key may use, else the key's only
// model.
func defaultModel(k apikey.Key, st router.HarnessState) (string, bool) {
	if d := st.DefaultModel; d != "" && (len(k.Models) == 0 || contains(k.Models, d)) {
		return d, true
	}
	if len(k.Models) == 1 {
		return k.Models[0], true
	}
	return "", false
}

func (b *CoreBackend) harnessState(ctx context.Context, h string) (router.HarnessState, error) {
	p, err := b.Core.Probe(ctx)
	if err != nil {
		return router.HarnessState{}, err
	}
	return p.Harnesses[h], nil
}

// resolve turns the model name a caller sent into what to run: a task
// kind for a router key ("" lets AFK guess it from the prompt), a model
// for a harness key.
func (b *CoreBackend) resolve(ctx context.Context, k apikey.Key, name string) (task, model string, fail *Outcome) {
	no := func(o Outcome) (string, string, *Outcome) { return "", "", &o }
	if k.Kind == apikey.KindRouter {
		n := strings.TrimPrefix(name, "afk/")
		if n == "auto" || n == "afk" || n == "" {
			return "", "", nil
		}
		if contains(router.Tasks, n) {
			return n, "", nil
		}
		return no(failure(404, KindNotFound, "this key routes by task: the model is one of %s (not %q)", strings.Join(RouterModels(), ", "), name))
	}
	n := strings.TrimPrefix(name, k.Harness+"/")
	st, err := b.harnessState(ctx, k.Harness)
	if err != nil {
		return no(failure(500, KindUpstream, "%v", err))
	}
	if !st.Installed {
		return no(failure(503, KindOverloaded, "%s is not installed on this machine", k.Harness))
	}
	if n == "" || n == "default" || n == k.Harness {
		d, ok := defaultModel(k, st)
		if !ok {
			return no(failure(400, KindInvalid, "%s doesn't say which model is its default; name one (GET /v1/models lists them)", k.Harness))
		}
		return "", d, nil
	}
	if !modelNameRE.MatchString(n) {
		return no(failure(400, KindInvalid, "%q is not a model name", name))
	}
	if len(k.Models) > 0 && !contains(k.Models, n) {
		return no(failure(404, KindNotFound, "this key is limited to %s on %s", strings.Join(k.Models, ", "), k.Harness))
	}
	if st.ModelsKnown && !contains(st.Models, n) {
		return no(failure(404, KindNotFound, "%s doesn't list %s for this account (GET /v1/models lists what it has)", k.Harness, n))
	}
	return "", n, nil
}

// Run answers one call.
func (b *CoreBackend) Run(ctx context.Context, call Call) Outcome {
	k := call.Key
	task, model, fail := b.resolve(ctx, k, call.Model)
	if fail != nil {
		return *fail
	}
	settings, err := b.Core.LoadSettings("")
	if err != nil {
		return failure(500, KindUpstream, "AFK's settings can't be read: %v", err)
	}

	// Where the CLI works. A key with no folder of its own gets a new
	// empty one for each call, removed afterwards, and runs read-only in
	// it: the call can only answer.
	dir, mode := k.Dir, k.RunMode()
	if dir == "" {
		mode = "read-only"
		d, err := os.MkdirTemp(b.TempDir, "afk-serve-")
		if err != nil {
			return failure(500, KindUpstream, "no working folder for the run: %v", err)
		}
		defer os.RemoveAll(d)
		dir = d
	} else if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return failure(500, KindUpstream, "this key's folder is not there any more; set it again in AFK")
	}

	c := b.Core.In(dir)
	c.NoTerminal = true
	flags := engine.RouteFlags{Repo: dir, Perm: mode, Effort: call.Effort, Task: task, NoPlan: !settings.ServePlanRuns}
	if k.Kind == apikey.KindHarness {
		flags.Harness, flags.Model = k.Harness, model
	}

	timeout := b.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	id := ""
	if b.RunsDir != "" {
		if rid, err := runrec.Reserve(b.RunsDir); err == nil {
			id = rid
		}
	}
	unreserve := func() {
		if id != "" {
			_ = os.Remove(filepath.Join(b.RunsDir, id+".json"))
			id = ""
		}
	}

	// The answer as it is written, from whichever attempt is running. A
	// failed attempt that had already written part of an answer ends the
	// call: another route can't take back what the caller has read.
	var mu sync.Mutex
	var dec *decoder
	var decFor string
	var usage *Usage
	streamed := false
	req := core.PrintRequest{Flags: flags, Prompt: call.Prompt}
	req.Line = func(r engine.Route, line []byte) {
		mu.Lock()
		defer mu.Unlock()
		if at := r.Harness + "/" + r.Model; dec == nil || decFor != at {
			format := ""
			if man, ok := harness.ManifestFor(r.Harness); ok {
				format = man.Stream.Format
			}
			dec, decFor = &decoder{format: format}, at
		}
		text := dec.line(line)
		usage = dec.usage
		if text != "" && call.Delta != nil {
			streamed = true
			call.Delta(text)
		}
	}
	req.Stop = func() bool {
		mu.Lock()
		defer mu.Unlock()
		return streamed
	}

	started := time.Now()
	res, err := c.Print(ctx, req, nil)
	ended := time.Now()
	if err != nil {
		unreserve()
		return printError(err)
	}
	mu.Lock()
	out := Outcome{Route: res.Route, Usage: usage, Streamed: streamed, Run: id}
	mu.Unlock()
	if id != "" {
		exit := res.Exit
		rec := runrec.Record{
			ID: id, Where: "serve", Key: k.Name, Route: res.Route.Redacted(), Exit: exit, Session: res.Session,
			StartedAt: runrec.Stamp(started), EndedAt: runrec.Stamp(ended),
			DurationS: int64(ended.Sub(started).Round(time.Second) / time.Second),
		}
		if _, err := runrec.Write(b.RunsDir, rec); err != nil {
			unreserve()
			out.Run = ""
		}
	}
	if res.OK {
		out.OK, out.Text = true, res.Output
		return out
	}
	tried := strings.Join(res.Tried, ", ")
	switch {
	case res.Interrupted && ctx.Err() == context.DeadlineExceeded:
		out.Status, out.Kind, out.Error = 504, KindUpstream, fmt.Sprintf("the run on %s passed AFK's limit of %s and was stopped", tried, timeout)
	case res.Interrupted:
		out.Status, out.Kind, out.Error = 499, KindUpstream, "the caller went away and the run was stopped"
	default:
		why := strings.TrimSpace(res.Error)
		switch oneshot.Classify(why) {
		case oneshot.KindPool:
			// A plan's own limit, or its sign-in: nothing a retry right
			// now fixes, so a gateway should move to its next provider.
			out.Status, out.Kind, out.RetryAfter = 429, KindRateLimit, time.Minute
		case oneshot.KindModel:
			out.Status, out.Kind = 404, KindNotFound
		default:
			out.Status, out.Kind = 502, KindUpstream
		}
		out.Error = fmt.Sprintf("no answer from %s: %s", tried, cutText(why, 400))
	}
	return out
}

// printError is a call that never reached a CLI.
func printError(err error) Outcome {
	var plan *core.PlanRunsError
	var usage *core.UsageError
	var missing *core.NotInstalledError
	var noRoute *core.NoRouteError
	switch {
	case errors.As(err, &plan):
		who := "a CLI"
		if plan.Harness != "" {
			who = plan.Harness
		}
		return failure(403, KindPermission, "this call would run %s on its own sign-in, and that is switched off on this AFK. Its owner can turn it on in AFK's Keys screen, or with: afk config set serve.plan_runs true", who)
	case errors.As(err, &usage):
		return failure(400, KindInvalid, "%s", usage.Msg)
	case errors.As(err, &missing):
		return failure(503, KindOverloaded, "%s", missing.Msg)
	case errors.As(err, &noRoute):
		o := failure(503, KindOverloaded, "%s", noRoute.Msg)
		o.RetryAfter = time.Minute
		return o
	}
	return failure(500, KindUpstream, "%v", err)
}

// SeedLimiter gives the limiter the served runs of the last 24 hours, by
// key, so restarting afk serve doesn't give each key a fresh day.
func SeedLimiter(l *apikey.Limiter, runsDir string, now time.Time) {
	by := map[string][]time.Time{}
	for _, r := range runrec.Load(runsDir, now.Add(-24*time.Hour)) {
		if r.Where != "serve" || r.Key == "" {
			continue
		}
		if t, err := time.Parse(time.RFC3339, r.StartedAt); err == nil {
			by[r.Key] = append(by[r.Key], t)
		}
	}
	names := make([]string, 0, len(by))
	for n := range by {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		l.Seed(n, by[n])
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func cutText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && (s[n]&0xC0) == 0x80 {
		n--
	}
	return s[:n] + "…"
}
