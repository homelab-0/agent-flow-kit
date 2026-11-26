// Package oneshot is afk -p: run the chosen CLI headless, read its answer
// from the JSON it prints, and when it fails, try the next route, up to
// three attempts. It decides nothing about routing itself: the caller
// supplies how to run a route and how to ask the router for the next one.
package oneshot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/failsig"
)

// MaxAttempts is how many routes one run tries.
const MaxAttempts = 3

// Kind is what a failure says about the route.
type Kind string

const (
	// KindModel: the provider refused this model; it is set aside.
	KindModel Kind = "model"
	// KindPool: a sign-in, quota or rate-limit failure; the pool is set
	// aside.
	KindPool Kind = "pool"
	// KindOther: anything else; this run stays away from that CLI.
	KindOther Kind = "other"
)

var (
	modelRE = regexp.MustCompile(`\b(model_not_found|does\s+not\s+have\s+access|not\s+authorized\s+for\s+model|unknown\s+model)\b`)
)

// Classify reads a failure's text (afk_cli_failure_kind). Pass error text
// only: an answer that talks about HTTP 429 says nothing about the pool.
func Classify(text string) Kind {
	switch {
	case modelRE.MatchString(strings.ToLower(text)):
		return KindModel
	case failsig.Pool(text):
		return KindPool
	}
	return KindOther
}

// PoolReason is the reason recorded for a pool failure: CLI wording for a
// spent plan gets a "quota: " prefix, so the router keeps the pool aside
// for the quota TTL rather than the transient one.
func PoolReason(why string) string {
	if failsig.NeedsQuotaPrefix(why) {
		return "quota: " + why
	}
	return why
}

// Output is what one headless run left behind.
type Output struct {
	Stdout []byte
	Stderr []byte
	// Answer is the text file a CLI wrote its answer to (Codex), if any.
	Answer []byte
	// Exit is the CLI's exit status (127 when it could not be started).
	Exit int
	// LaunchError is set when the route could not be launched at all.
	LaunchError string
	// Mode is the permission mode it ran in; ModeNote says why when it is
	// stricter than asked.
	Mode, ModeNote string
	// ConfigNote says what the run did about the directory's own settings
	// outside a trusted repository.
	ConfigNote string
}

// ErrReported is an answer document that says the run failed.
var errReported = errors.New("the CLI reported an error")

// Answer reads the answer from a run's stdout (one or more JSON values,
// as the CLIs print them in JSON mode) and the answer file (afk_cli_result).
// A document that reports a failure returns its error text and false.
func Answer(stdout, answerFile []byte) (string, bool) {
	vals, parsed := decodeAll(stdout)
	if parsed {
		for _, v := range vals {
			if isFailure(v) {
				return failureText(vals), false
			}
		}
	}
	if len(answerFile) > 0 {
		return string(answerFile), true
	}
	if parsed {
		var b strings.Builder
		for _, v := range vals {
			m, ok := v.(map[string]any)
			if !ok {
				continue
			}
			s := firstString(m, "result", "response", "text")
			if s == "" {
				if part, ok := m["part"].(map[string]any); ok {
					s, _ = part["text"].(string)
				}
			}
			b.WriteString(s)
		}
		if b.Len() > 0 {
			return b.String(), true
		}
	}
	return string(stdout), true
}

// decodeAll reads every JSON value in b. parsed is false when b is empty
// or is not JSON throughout, as `jq -s` would refuse it.
func decodeAll(b []byte) ([]any, bool) {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	var out []any
	for {
		var v any
		err := dec.Decode(&v)
		if err == io.EOF {
			return out, true
		}
		if err != nil {
			return nil, false
		}
		out = append(out, v)
	}
}

func isFailure(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	if e, ok := m["is_error"].(bool); ok && e {
		return true
	}
	t, _ := m["type"].(string)
	return t == "error" || t == "turn.failed"
}

// failureText is the first error message in the values: error.data.message,
// error.message, the result of an is_error document, or message.
func failureText(vals []any) string {
	for _, v := range vals {
		// Only a value that reports the failure: a status line before it
		// ("connected") is not the reason.
		if !isFailure(v) {
			continue
		}
		m := v.(map[string]any)
		var cands []any
		switch e := m["error"].(type) {
		case map[string]any:
			if d, ok := e["data"].(map[string]any); ok {
				cands = append(cands, d["message"])
			}
			cands = append(cands, e["message"])
		case string:
			cands = append(cands, e)
		}
		if ie, ok := m["is_error"].(bool); ok && ie {
			cands = append(cands, m["result"])
		}
		cands = append(cands, m["message"])
		for _, c := range cands {
			if s, ok := c.(string); ok && s != "" {
				return s
			}
		}
	}
	return errReported.Error()
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if s, ok := m[k].(string); ok && s != "" {
			return s
		}
	}
	return ""
}

// Request is one -p run.
type Request struct {
	// First is the route the router chose (or the pinned one).
	First engine.Route
	// Pinned: --harness or --model was given, so a failure is reported,
	// never moved to another route.
	Pinned bool
	// Harnesses are the CLIs the run may use.
	Harnesses []string
	// Failover is where a failed run may go next: "any" (or empty) for
	// the next best route, "same-pool" for another model on the same
	// CLI and plan (so the prompt goes to no other account), "none" to
	// report the failure.
	Failover string
	// Effort, when given on the command line, applies to every route.
	Effort string
	// Mode is the permission mode asked for. Each later attempt runs at
	// this mode or the strictest one an earlier attempt actually ran in,
	// whichever is stricter: failover never loosens it.
	Mode string
	// FirstPool is the pool the first route's failures are recorded
	// against when the route names none (a pinned route).
	FirstPool string
}

// Deps is how a run reaches the outside world.
type Deps struct {
	// Run starts the route headless and waits for it.
	Run func(ctx context.Context, r engine.Route, mode string) Output
	// Next asks the router again, limited to these CLIs and, when pool
	// is set, to routes that pool serves. ok is false when nothing there
	// can do the task.
	Next func(ctx context.Context, only []string, pool string) (r engine.Route, ok bool)
	// Mark records a model or pool failure for the router (and so for
	// the next run). reason is at most 160 bytes.
	Mark func(kind Kind, pool, model, reason string)
	// Note is a line for the person, on stderr.
	Note func(string)
	// Changed is how many files in the working copy changed since the run
	// began (nil when that isn't known, as outside a git repository). A
	// route that fails after editing files leaves them for the next one.
	Changed func() *int
}

// Result is how the run ended.
type Result struct {
	OK       bool
	Route    engine.Route // the route that answered
	Attempts int
	Output   string
	// Tried lists harness/model for every attempt, in order.
	Tried []string
	// Exit is the last attempt's exit status (1 when it exited 0 but its
	// JSON reported a failure).
	Exit int
	// Error is the last failure's text, at most 600 bytes.
	Error string
	// NoOther: the run stopped because no other route was usable.
	NoOther bool
	// Interrupted: the run was cancelled (Ctrl-C).
	Interrupted bool
}

// Do runs the request: the first route, then, on a failure that is not
// pinned, the next best route, up to MaxAttempts.
func Do(ctx context.Context, req Request, d Deps) Result {
	route := req.First
	mode := req.Mode
	if mode == "" {
		mode = "ask"
	}
	var tried []string
	triedSet := map[string]bool{}
	var avoid []string
	firstPool := req.First.EntitlementPool
	if firstPool == "" {
		firstPool = req.FirstPool
	}
	for attempt := 1; ; attempt++ {
		out := d.Run(ctx, route, mode)
		if out.ModeNote != "" && d.Note != nil {
			d.Note("afk: " + out.ModeNote)
		}
		if out.ConfigNote != "" && d.Note != nil {
			d.Note("afk: " + out.ConfigNote)
		}
		// A later attempt never runs looser than this one did.
		if out.Mode != "" && rank(out.Mode) < rank(mode) {
			mode = out.Mode
		}
		id := route.Harness + "/" + route.Model
		tried = append(tried, id)
		triedSet[id] = true
		if ctx.Err() != nil {
			return Result{Tried: tried, Attempts: attempt, Exit: 130, Error: "interrupted", Interrupted: true}
		}
		rc := out.Exit
		var text string
		ok := false
		if out.LaunchError != "" {
			if rc == 0 {
				rc = 127
			}
		} else {
			text, ok = Answer(out.Stdout, out.Answer)
			if rc == 0 && ok {
				return Result{OK: true, Route: route, Attempts: attempt, Output: strings.TrimRight(text, "\n"), Tried: tried}
			}
		}
		if rc == 0 {
			rc = 1
		}
		why := reason(out, text, ok)
		// Classify, and record, only the error text: the answer may talk
		// about status codes and would set the wrong kind of mark.
		errText := strings.TrimSpace(errorText(out, text, ok))
		kind := Classify(errText)
		pool := route.EntitlementPool
		if pool == "" && attempt == 1 {
			pool = req.FirstPool
		}
		mark := func() {
			if d.Mark == nil {
				return
			}
			switch kind {
			case KindModel:
				d.Mark(kind, pool, route.Model, cut(errText, 160))
			case KindPool:
				if pool != "" {
					d.Mark(kind, pool, route.Model, cut(PoolReason(errText), 160))
				}
			}
		}
		// Even a run that stops here tells the router, so the next run
		// does not walk into the same failure.
		mark()
		// Recording can wait on the signals lock; a Ctrl-C meanwhile
		// ends the run as interrupted, whatever the route.
		if ctx.Err() != nil {
			return Result{Tried: tried, Attempts: attempt, Exit: 130, Error: "interrupted", Interrupted: true}
		}
		fail := Result{Tried: tried, Attempts: attempt, Exit: rc, Error: why}
		if req.Pinned || route.Pinned || attempt >= MaxAttempts || req.Failover == "none" {
			return fail
		}
		if kind == KindOther {
			avoid = append(avoid, route.Harness)
		}
		if req.Failover == "same-pool" {
			// The prompt stays with the CLI and plan the router chose
			// first.
			req.Harnesses = without([]string{req.First.Harness}, avoid)
		}
		only := ""
		if req.Failover == "same-pool" {
			// Ask for the first pool only: a better ranked route through
			// another pool must not hide a model the plan still has.
			only = firstPool
		}
		next, found := nextRoute(ctx, req, d, avoid, only, triedSet)
		if found && req.Failover == "same-pool" && next.EntitlementPool != firstPool {
			found = false
		}
		if !found {
			fail.NoOther = true
			return fail
		}
		if req.Effort != "" {
			next = next.WithEffort(req.Effort)
		}
		if d.Note != nil {
			d.Note("afk: " + id + " failed (" + string(kind) + "); trying " + next.Harness + " / " + next.Model)
			if d.Changed != nil {
				if n := d.Changed(); n != nil && *n > 0 {
					d.Note(fmt.Sprintf("afk: %s left %d changed %s in the working copy; %s / %s starts from them", id, *n, plural(*n, "file", "files"), next.Harness, next.Model))
				}
			}
		}
		route = next
	}
}

// nextRoute asks the router for the next route outside the avoided CLIs.
// A route already tried in this run (the router may not have seen the
// failure, if the signals file could not be written) moves the run off
// that CLI too, rather than spending an attempt on it again.
func nextRoute(ctx context.Context, req Request, d Deps, avoid []string, pool string, tried map[string]bool) (engine.Route, bool) {
	for range req.Harnesses {
		allowed := without(req.Harnesses, avoid)
		if len(allowed) == 0 || d.Next == nil {
			return engine.Route{}, false
		}
		r, ok := d.Next(ctx, allowed, pool)
		if !ok || r.Harness == "" {
			return engine.Route{}, false
		}
		if !tried[r.Harness+"/"+r.Model] {
			return r, true
		}
		avoid = append(avoid, r.Harness)
	}
	return engine.Route{}, false
}

func without(list, drop []string) []string {
	var out []string
	for _, x := range list {
		keep := true
		for _, y := range drop {
			if x == y {
				keep = false
				break
			}
		}
		if keep {
			out = append(out, x)
		}
	}
	return out
}

// reason is the failure text for the person and for Classify: what the
// CLI's JSON said, then the start of its stderr, without escape codes, at
// most 600 bytes.
func reason(out Output, text string, ok bool) string {
	var parts []string
	if out.LaunchError != "" {
		parts = append(parts, out.LaunchError)
	} else if !ok && text != "" {
		parts = append(parts, cut(text, 500))
	}
	if s := strings.TrimSpace(cut(string(out.Stderr), 1500)); s != "" {
		parts = append(parts, s)
	}
	if out.LaunchError == "" && ok {
		// Exited non-zero without an error document: whatever it printed.
		if s := strings.TrimSpace(cut(text, 500)); s != "" {
			parts = append(parts, s)
		}
	}
	why := strings.ReplaceAll(strings.Join(parts, "\n"), "\x1b", "")
	return cut(why, 600)
}

// errorText is the part of a failure that may be classified: the launch
// error, the error document's message, stderr, and stdout that isn't JSON
// (a CLI printing its own error). An answer the CLI delivered in JSON or an
// answer file, before exiting non-zero, is left out: it is the model's own
// text and may discuss rate limits or quotas as a topic.
func errorText(out Output, text string, ok bool) string {
	parts := []string{out.LaunchError}
	if out.LaunchError == "" {
		_, parsed := decodeAll(out.Stdout)
		if !ok || (!parsed && len(out.Answer) == 0) {
			parts = append(parts, cut(text, 500))
		}
	}
	parts = append(parts, cut(string(out.Stderr), 1500))
	return strings.Join(parts, "\n")
}

// cut shortens s to at most n bytes without splitting a character.
func cut(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// rank orders the permission modes, strictest first.
func rank(m string) int {
	for i, x := range []string{"read-only", "ask", "edits", "auto", "yolo"} {
		if x == m {
			return i
		}
	}
	return 1
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
