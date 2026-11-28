package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/serve"
)

const keysUsage = `afk keys — AFK's own API keys, for afk serve

A gateway (LiteLLM and the like) or any OpenAI- or Anthropic-compatible
client calls afk serve with one of these keys.

  afk keys [--json]
      every key: its kind, what it reaches, its limits

  afk keys add <name> [options]
      make a key and print it. It is shown this once; AFK keeps only a
      hash. Without --harness it is a router key: the caller asks for
      afk/auto (or afk/coding, afk/review, ...) and AFK picks the CLI and
      model, as afk -p does.

      --harness <cli>     a harness key instead: it reaches that one CLI,
                          the caller names the model (grok/<model>), and
                          AFK makes no routing decision
      --models a,b        the only models a harness key may name
      --per-minute N      requests a minute   (0 turns a limit off)
      --per-day N         requests a day
      --concurrent N      runs at the same time
      --no-limits         all three off
      --dir <folder>      let calls work in this folder (see below)
      --mode <mode>       read-only (default), edits, auto or yolo

  afk keys set <name> [the options of add] [--no-dir]
      change a key's limits, models or folder

  afk keys rotate <name>      a new secret; the old one stops at once
  afk keys revoke <name>      stop the key working, keep its record
  afk keys rm <name>          delete the key

What a call may do. By default a call can only answer: its run is
read-only, in a new empty folder that is deleted afterwards, so it sees
and changes none of your files. --dir and --mode let one key's calls do
agent work in one folder instead.

Limits. A new router key starts at 10 a minute, 500 a day and 2 at once;
a harness key at 6, 200 and 1. A call over a limit gets HTTP 429, so a
gateway moves on to its next provider.
`

func keysEnv() (store *apikey.Store, paths config.Paths) {
	home, _ := os.UserHomeDir()
	paths = config.PathsFor(home, os.Getenv)
	return &apikey.Store{Path: apikey.PathFor(paths.State, os.Getenv)}, paths
}

type keyFlags struct {
	json              bool
	harness           string
	models            []string
	modelsSet         bool
	perMinute, perDay *int
	concurrent        *int
	noLimits          bool
	dir, mode         string
	dirSet, modeSet   bool
	noDir             bool
	args              []string
}

func parseKeyFlags(argv []string) (keyFlags, error) {
	var f keyFlags
	num := func(name, v string) (*int, error) {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("%s takes a count, or 0 for off", name)
		}
		return &n, nil
	}
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		name, val, hasVal := strings.Cut(a, "=")
		next := func() (string, error) {
			if hasVal {
				return val, nil
			}
			if i+1 >= len(argv) {
				return "", fmt.Errorf("%s needs a value", name)
			}
			i++
			return argv[i], nil
		}
		var err error
		var v string
		switch name {
		case "--json":
			f.json = true
		case "--no-limits":
			f.noLimits = true
		case "--no-dir":
			f.noDir = true
		case "--harness":
			f.harness, err = next()
		case "--models":
			if v, err = next(); err == nil {
				f.modelsSet = true
				for _, m := range strings.Split(v, ",") {
					if m = strings.TrimSpace(m); m != "" {
						f.models = append(f.models, m)
					}
				}
			}
		case "--per-minute":
			if v, err = next(); err == nil {
				f.perMinute, err = num(name, v)
			}
		case "--per-day":
			if v, err = next(); err == nil {
				f.perDay, err = num(name, v)
			}
		case "--concurrent":
			if v, err = next(); err == nil {
				f.concurrent, err = num(name, v)
			}
		case "--dir":
			f.dir, err = next()
			f.dirSet = true
		case "--mode":
			f.mode, err = next()
			f.modeSet = true
		default:
			if strings.HasPrefix(a, "-") && len(a) > 1 {
				return f, fmt.Errorf("unknown option %s", a)
			}
			f.args = append(f.args, a)
		}
		if err != nil {
			return f, err
		}
	}
	return f, nil
}

// limits applies the limit flags to base.
func (f keyFlags) limits(base apikey.Limits) apikey.Limits {
	if f.noLimits {
		base = apikey.Limits{}
	}
	if f.perMinute != nil {
		base.PerMinute = *f.perMinute
	}
	if f.perDay != nil {
		base.PerDay = *f.perDay
	}
	if f.concurrent != nil {
		base.Concurrent = *f.concurrent
	}
	return base
}

func (f keyFlags) limitsGiven() bool {
	return f.noLimits || f.perMinute != nil || f.perDay != nil || f.concurrent != nil
}

func keysCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) > 0 && (argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help") {
		fmt.Fprint(stdout, keysUsage)
		return 0
	}
	sub := "list"
	if len(argv) > 0 && !strings.HasPrefix(argv[0], "-") {
		sub, argv = argv[0], argv[1:]
	}
	f, err := parseKeyFlags(argv)
	if err != nil {
		fmt.Fprintln(stderr, "afk keys:", err)
		return 2
	}
	store, _ := keysEnv()
	fail := func(err error) int {
		fmt.Fprintln(stderr, "afk keys:", err)
		return 1
	}
	name := func() (string, bool) {
		if len(f.args) != 1 {
			fmt.Fprintf(stderr, "afk keys %s: name one key\n", sub)
			return "", false
		}
		return f.args[0], true
	}
	switch sub {
	case "list", "ls":
		keys, err := store.List()
		if err != nil {
			return fail(err)
		}
		if f.json {
			return printJSON(stdout, stderr, map[string]any{"schema": "afk-keys-list/1", "keys": keyDocs(keys)})
		}
		if len(keys) == 0 {
			fmt.Fprintln(stdout, "No keys yet. Make one with: afk keys add <name>   (afk keys --help)")
			return 0
		}
		for _, k := range keys {
			fmt.Fprintln(stdout, keyLine(k))
		}
		return 0
	case "show":
		n, ok := name()
		if !ok {
			return 2
		}
		k, err := store.Get(n)
		if err != nil {
			return fail(err)
		}
		if f.json {
			return printJSON(stdout, stderr, keyDoc(k))
		}
		fmt.Fprintln(stdout, keyLine(k))
		return 0
	case "add", "new", "create":
		n, ok := name()
		if !ok {
			return 2
		}
		kind := apikey.KindRouter
		if f.harness != "" {
			kind = apikey.KindHarness
			if err := checkKeyHarness(f.harness); err != nil {
				return fail(err)
			}
		}
		dir, err := keyDir(f.dir)
		if err != nil {
			return fail(err)
		}
		lim := f.limits(apikey.DefaultLimits(kind))
		k, token, err := store.Create(apikey.New{Name: n, Kind: kind, Harness: f.harness, Models: f.models, Limits: &lim, Dir: dir, Mode: f.mode})
		if err != nil {
			return fail(err)
		}
		if kind == apikey.KindHarness {
			display, vendor := keyHarnessNames(f.harness)
			for _, l := range serve.HarnessKeyWarning(display, vendor, k.Limits) {
				fmt.Fprintln(stderr, l)
			}
			if s, err := core.New().LoadSettings(""); err == nil && !s.ServePlanRuns {
				fmt.Fprintln(stderr, "This key won't answer yet: your CLIs' own sign-ins are switched off for afk serve.")
				fmt.Fprintln(stderr, "Turn them on with: afk config set serve.plan_runs true")
			}
			fmt.Fprintln(stderr)
		}
		return printNewKey(stdout, stderr, k, token, f.json, "made")
	case "rotate":
		n, ok := name()
		if !ok {
			return 2
		}
		k, token, err := store.Rotate(n)
		if err != nil {
			return fail(err)
		}
		return printNewKey(stdout, stderr, k, token, f.json, "rotated")
	case "revoke":
		n, ok := name()
		if !ok {
			return 2
		}
		k, err := store.Revoke(n)
		if err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "Revoked %s. It no longer works; afk keys rotate %s brings it back with a new secret.\n", k.Name, k.Name)
		return 0
	case "rm", "remove", "delete":
		n, ok := name()
		if !ok {
			return 2
		}
		if err := store.Delete(n); err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "Deleted %s.\n", n)
		return 0
	case "set", "limits":
		n, ok := name()
		if !ok {
			return 2
		}
		k, err := store.Get(n)
		if err != nil {
			return fail(err)
		}
		if f.harness != "" {
			return fail(errors.New("a key's harness can't be changed; make another key"))
		}
		changed := false
		if f.limitsGiven() {
			if k, err = store.SetLimits(n, f.limits(k.Limits)); err != nil {
				return fail(err)
			}
			changed = true
		}
		if f.modelsSet {
			if k, err = store.SetModels(n, f.models); err != nil {
				return fail(err)
			}
			changed = true
		}
		if f.dirSet || f.modeSet || f.noDir {
			dir, mode := k.Dir, k.Mode
			if f.dirSet {
				if dir, err = keyDir(f.dir); err != nil {
					return fail(err)
				}
			}
			if f.modeSet {
				mode = f.mode
			}
			if f.noDir {
				dir, mode = "", ""
			}
			if k, err = store.SetRun(n, dir, mode); err != nil {
				return fail(err)
			}
			changed = true
		}
		if !changed {
			fmt.Fprintln(stderr, "afk keys set: nothing to change (see afk keys --help)")
			return 2
		}
		if f.json {
			return printJSON(stdout, stderr, keyDoc(k))
		}
		fmt.Fprintln(stdout, keyLine(k))
		return 0
	}
	fmt.Fprintf(stderr, "afk keys: unknown command %q\n\n%s", sub, keysUsage)
	return 2
}

// checkKeyHarness: a harness key is for a CLI AFK launches.
func checkKeyHarness(h string) error {
	for _, r := range core.Routable {
		if r == h {
			return nil
		}
	}
	return fmt.Errorf("%s is not a CLI AFK runs (one of %s)", h, strings.Join(core.Routable, ", "))
}

func keyHarnessNames(h string) (display, vendor string) {
	if a, ok := harness.Lookup(h); ok {
		return a.Display, a.Vendor
	}
	return h, ""
}

// keyDir is a --dir as an absolute path.
func keyDir(d string) (string, error) {
	if d == "" {
		return "", nil
	}
	if d == "~" || strings.HasPrefix(d, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		d = filepath.Join(home, strings.TrimPrefix(d, "~"))
	}
	return filepath.Abs(d)
}

func printNewKey(stdout, stderr io.Writer, k apikey.Key, token string, asJSON bool, what string) int {
	if asJSON {
		doc := keyDoc(k)
		doc["key"] = token
		return printJSON(stdout, stderr, doc)
	}
	fmt.Fprintf(stderr, "Key %s %s. This is the only time it is shown:\n\n", k.Name, what)
	fmt.Fprintln(stdout, token)
	fmt.Fprintf(stderr, "\n%s\n", keyLine(k))
	fmt.Fprintf(stderr, "Model to ask for: %s\n", keyModelHint(k))
	return 0
}

func keyModelHint(k apikey.Key) string {
	if k.Kind == apikey.KindRouter {
		return "afk/auto, or afk/<task> (" + strings.Join(serve.RouterModels()[1:], ", ") + ")"
	}
	return k.Harness + "/<model> (GET /v1/models lists them)"
}

// keyLine is one key on one line.
func keyLine(k apikey.Key) string {
	what := "router · afk/auto and afk/<task>"
	if k.Kind == apikey.KindHarness {
		what = "harness · " + k.Harness
		if len(k.Models) > 0 {
			what += " (" + strings.Join(k.Models, ", ") + ")"
		}
	}
	does := "answers only"
	if k.Dir != "" {
		does = k.RunMode() + " in " + k.Dir
	}
	state := ""
	if !k.Active() {
		state = " · REVOKED"
	}
	return fmt.Sprintf("%-16s %s  %s · %s · %s%s", k.Name, k.Hint(), what, k.Limits, does, state)
}

func keyDoc(k apikey.Key) map[string]any {
	doc := map[string]any{
		"name": k.Name, "id": k.ID, "kind": k.Kind, "active": k.Active(), "created": k.Created,
		"limits": k.Limits, "mode": k.RunMode(),
	}
	if k.Harness != "" {
		doc["harness"] = k.Harness
	}
	if len(k.Models) > 0 {
		doc["models"] = k.Models
	}
	if k.Dir != "" {
		doc["dir"] = k.Dir
	}
	if k.Rotated != nil {
		doc["rotated"] = k.Rotated
	}
	if k.Revoked != nil {
		doc["revoked"] = k.Revoked
	}
	return doc
}

func keyDocs(keys []apikey.Key) []map[string]any {
	out := []map[string]any{}
	for _, k := range keys {
		out = append(out, keyDoc(k))
	}
	return out
}
