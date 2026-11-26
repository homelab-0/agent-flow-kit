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
	"io"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
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
	modelRE = regexp.MustCompile(`(model_not_found|does\s+not\s+have\s+access|not\s+authorized\s+for\s+model|unknown\s+model)`)
	poolRE  = regexp.MustCompile(`(401|unauthorized|not\s+logged\s+in|please\s+log\s?in|429|rate[\s_]limit|quota|usage\s+limit|credit\s+balance|exhausted|overloaded|529)`)
	// CLI wording such as "usage limit reached" is a quota event the
	// router would not otherwise recognise as one.
	quotaWordsRE = regexp.MustCompile(`(usage\s+limit|credit\s+balance)`)
	quotaRE      = regexp.MustCompile(`(429|rate_limit|rate\s+limit|quota)`)
)

// Classify reads a failure's text (afk_cli_failure_kind).
func Classify(text string) Kind {
	t := strings.ToLower(text)
	switch {
	case modelRE.MatchString(t):
		return KindModel
	case poolRE.MatchString(t):
		return KindPool
	}
	return KindOther
}

// PoolReason is the reason recorded for a pool failure: CLI wording for a
// spent plan gets a "quota: " prefix, so the router keeps the pool aside
// for the quota TTL rather than the transient one.
func PoolReason(why string) string {
	lw := strings.ToLower(why)
	if quotaWordsRE.MatchString(lw) && !quotaRE.MatchString(lw) {
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
	// Effort, when given on the command line, applies to every route.
	Effort string
	// FirstPool is the pool the first route's failures are recorded
	// against when the route names none (a pinned route).
	FirstPool string
}

// Deps is how a run reaches the outside world.
type Deps struct {
	// Run starts the route headless and waits for it.
	Run func(ctx context.Context, r engine.Route) Output
	// Next asks the router again, limited to these CLIs. ok is false when
	// nothing there can do the task.
	Next func(ctx context.Context, only []string) (r engine.Route, ok bool)
	// Mark records a model or pool failure for the router (and so for
	// the next run). reason is at most 160 bytes.
	Mark func(kind Kind, pool, model, reason string)
	// Note is a line for the person, on stderr.
	Note func(string)
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
	var tried []string
	triedSet := map[string]bool{}
	var avoid []string
	for attempt := 1; ; attempt++ {
		out := d.Run(ctx, route)
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
		kind := Classify(why)
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
				d.Mark(kind, pool, route.Model, cut(why, 160))
			case KindPool:
				if pool != "" {
					d.Mark(kind, pool, route.Model, cut(PoolReason(why), 160))
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
		if req.Pinned || route.Pinned || attempt >= MaxAttempts {
			return fail
		}
		if kind == KindOther {
			avoid = append(avoid, route.Harness)
		}
		next, found := nextRoute(ctx, req, d, avoid, triedSet)
		if !found {
			fail.NoOther = true
			return fail
		}
		if req.Effort != "" {
			next = next.WithEffort(req.Effort)
		}
		if d.Note != nil {
			d.Note("afk: " + id + " failed (" + string(kind) + "); trying " + next.Harness + " / " + next.Model)
		}
		route = next
	}
}

// nextRoute asks the router for the next route outside the avoided CLIs.
// A route already tried in this run (the router may not have seen the
// failure, if the signals file could not be written) moves the run off
// that CLI too, rather than spending an attempt on it again.
func nextRoute(ctx context.Context, req Request, d Deps, avoid []string, tried map[string]bool) (engine.Route, bool) {
	for range req.Harnesses {
		allowed := without(req.Harnesses, avoid)
		if len(allowed) == 0 || d.Next == nil {
			return engine.Route{}, false
		}
		r, ok := d.Next(ctx, allowed)
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
