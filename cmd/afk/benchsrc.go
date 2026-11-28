package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/bench"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/router"
)

const benchSourceUsage = `afk bench source — the leaderboards AFK blends into its scores

  afk bench source [list]                 every source, on or off, and what it scores
  afk bench source add <id> <url|file> [tasks]  add a leaderboard of your own
        [--name N] [--rows PATH] [--model FIELD] [--score FIELD] [--lower]
        [--format json|yaml|csv] [--weight W] [--key env:NAME --key-header H]
  afk bench source test <id>              read it now and show what AFK makes of it
  afk bench source on|off <id>            turn a source on or off
  afk bench source rm <id>                remove a source you added
  afk bench weight <id> <weight> [tasks]  a source's weight in the blend

tasks are comma-separated: complex, standard, review, architecture,
security, webdev, research, frontier (or their full names). Fields you
leave out are detected from the data. add reads the source once first and
saves it only when AFK could read a score for at least one model.
`

// taskAlias turns a short task name into its kind.
var taskAlias = map[string]string{
	"complex": "coding_complex", "standard": "coding_standard", "review": "coding_review", "coding": "coding_complex",
	"arch": "architecture", "architecture": "architecture", "security": "security", "webdev": "webdev", "web": "webdev",
	"research": "research", "frontier": "frontier_synthesis",
}

func parseTasks(s string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, t := range strings.Split(s, ",") {
		t = strings.TrimSpace(strings.ToLower(t))
		if t == "" {
			continue
		}
		k := taskAlias[t]
		if k == "" {
			for _, kk := range config.BenchTasks {
				if kk == t {
					k = kk
				}
			}
		}
		if k == "" {
			return nil, fmt.Errorf("unknown task %q (complex, standard, review, architecture, security, webdev, research, frontier)", t)
		}
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("name at least one task it scores")
	}
	return out, nil
}

// benchSourceList is every extra source, built-in and the user's, with
// whether it is on and its key read from the environment.
func benchSourceList(s config.Settings, getenv func(string) string) []bench.Source {
	var out []bench.Source
	for _, p := range bench.Presets() {
		p.On = s.BenchSourceOr(p.ID, p.On)
		if p.KeyEnv != "" {
			p.Key = getenv(p.KeyEnv)
		}
		out = append(out, p)
	}
	ids := make([]string, 0, len(s.BenchCustom))
	for id := range s.BenchCustom {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		c := s.BenchCustom[id]
		src := bench.Source{ID: id, Name: c.Name, URL: c.URL, File: c.File, Format: c.Format, Rows: c.Rows,
			Model: c.Model, Score: c.Score, Tasks: c.Tasks, Weight: 1, KeyHeader: c.KeyHeader, Measures: c.Measures, On: true}
		if src.Name == "" {
			src.Name = id
		}
		if c.Lower != nil {
			src.Lower = *c.Lower
		}
		if c.Weight != nil {
			src.Weight = *c.Weight
		}
		if c.Enabled != nil {
			src.On = *c.Enabled
		}
		if r, err := config.ParseSecretRef(c.Key); err == nil && r.Kind == "env" {
			src.KeyEnv, src.Key = r.Arg, getenv(r.Arg)
		}
		src.About = "Your own leaderboard, from " + sourceWhere(src) + "."
		if src.Measures == "" && src.Score != "" {
			src.Measures = src.Score + " from " + filepath.Base(sourceWhere(src))
		}
		out = append(out, src)
	}
	return out
}

func sourceWhere(s bench.Source) string {
	if s.File != "" {
		return s.File
	}
	return s.URL
}

func findSource(list []bench.Source, id string) (bench.Source, bool) {
	for _, s := range list {
		if s.ID == id {
			return s, true
		}
	}
	return bench.Source{}, false
}

func benchSourceCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) > 0 && (argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help") {
		fmt.Fprint(stdout, benchSourceUsage)
		return 0
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		fmt.Fprintln(stderr, "afk bench source: no home directory")
		return 1
	}
	env := config.Env{Home: home, Getenv: os.Getenv}
	paths := config.PathsFor(home, os.Getenv)
	st, err := config.Resolve(env)
	if err != nil {
		fmt.Fprintln(stderr, "afk bench source:", err)
		return 1
	}
	list := benchSourceList(st, os.Getenv)
	sub := "list"
	if len(argv) > 0 {
		sub, argv = argv[0], argv[1:]
	}
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "afk bench source "+sub+": "+format+"\n", a...)
		return 1
	}
	switch sub {
	case "list", "ls":
		for _, s := range list {
			state := "on "
			if !s.On {
				state = "off"
			}
			kind := "built-in"
			if !s.Builtin {
				kind = "yours"
			}
			fmt.Fprintf(stdout, "%s  %-20s %-9s %s\n", state, s.ID, kind, strings.Join(s.Tasks, ", "))
		}
		return 0
	case "test":
		if len(argv) != 1 {
			return fail("name one source")
		}
		s, ok := findSource(list, argv[0])
		if !ok {
			return fail("no source %s", argv[0])
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		p, err := bench.ProbeSource(ctx, sourceFetcher(), s, router.DefaultCatalogJSON())
		if err != nil {
			return fail("%s", err)
		}
		fmt.Fprint(stdout, probeText(s, p))
		return 0
	case "on", "off":
		if len(argv) != 1 {
			return fail("name one source")
		}
		s, ok := findSource(list, argv[0])
		if !ok {
			return fail("no source %s", argv[0])
		}
		key := "bench.sources." + s.ID + ".enabled"
		if !s.Builtin {
			key = "bench.custom." + s.ID + ".enabled"
		}
		if _, err := config.SetKey(paths, key, strconv.FormatBool(sub == "on"), false); err != nil {
			return fail("%s", err)
		}
		fmt.Fprintf(stdout, "%s is %s; the next afk bench sync uses it.\n", s.Name, sub)
		return 0
	case "rm", "remove":
		if len(argv) != 1 {
			return fail("name one source")
		}
		if s, ok := findSource(list, argv[0]); ok && s.Builtin {
			return fail("%s is built in; turn it off with afk bench source off %s", s.Name, s.ID)
		}
		ok, err := config.RemoveSection(paths, "bench.custom."+argv[0])
		if err != nil {
			return fail("%s", err)
		}
		if !ok {
			return fail("no source of yours called %s", argv[0])
		}
		fmt.Fprintf(stdout, "Removed %s.\n", argv[0])
		return 0
	case "add":
		msg, err := addBenchSource(paths, list, argv)
		if err != nil {
			return fail("%s", err)
		}
		fmt.Fprint(stdout, msg)
		return 0
	}
	fmt.Fprintf(stderr, "afk bench source: unknown command %s (see afk bench source --help)\n", sub)
	return 2
}

// addBenchSource reads a new source once and, when AFK can score at
// least one model from it, writes it to config.toml in one go.
func addBenchSource(paths config.Paths, list []bench.Source, argv []string) (string, error) {
	var pos []string
	src := bench.Source{Weight: 1, On: true}
	var key, keyHeader, weight string
	noCheck := false
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		// --option=value as well as --option value.
		attached, hasAttached := "", false
		if strings.HasPrefix(a, "--") {
			if k, v, ok := strings.Cut(a, "="); ok {
				a, attached, hasAttached = k, v, true
			}
		}
		val := func() (string, error) {
			if hasAttached {
				return attached, nil
			}
			if i+1 >= len(argv) {
				return "", fmt.Errorf("%s needs a value", a)
			}
			i++
			return argv[i], nil
		}
		var err error
		switch a {
		case "--name":
			src.Name, err = val()
		case "--rows":
			src.Rows, err = val()
		case "--model":
			src.Model, err = val()
		case "--score":
			src.Score, err = val()
		case "--format":
			src.Format, err = val()
		case "--weight":
			weight, err = val()
		case "--key":
			key, err = val()
		case "--key-header":
			keyHeader, err = val()
		case "--lower":
			src.Lower = true
		case "--no-check":
			noCheck = true
		default:
			if strings.HasPrefix(a, "--") {
				return "", fmt.Errorf("unknown option %s", a)
			}
			pos = append(pos, a)
		}
		if err != nil {
			return "", err
		}
	}
	if len(pos) < 2 || len(pos) > 3 {
		return "", errors.New("usage: afk bench source add <id> <url|file> [tasks]")
	}
	src.ID = pos[0]
	if !bench.IDRE.MatchString(src.ID) {
		return "", errors.New("an id is lower-case letters, digits and dashes")
	}
	if _, ok := findSource(list, src.ID); ok {
		return "", fmt.Errorf("there is already a source called %s", src.ID)
	}
	where := pos[1]
	if strings.HasPrefix(where, "http://") || strings.HasPrefix(where, "https://") {
		u, err := url.Parse(where)
		if err != nil || u.User != nil {
			return "", errors.New("a source URL can't hold a user name or password; use --key for a key")
		}
		src.URL = where
	} else {
		// A relative path is saved as the absolute path it names now.
		if !strings.HasPrefix(where, "~/") && !filepath.IsAbs(where) {
			abs, err := filepath.Abs(where)
			if err != nil {
				return "", err
			}
			where = abs
		}
		src.File = where
	}
	tasks := "complex"
	if len(pos) == 3 {
		tasks = pos[2]
	}
	var err error
	if src.Tasks, err = parseTasks(tasks); err != nil {
		return "", err
	}
	if key != "" {
		r, err := config.ParseSecretRef(key)
		if err != nil || r.Kind != "env" {
			return "", errors.New("--key takes env:NAME, the variable that holds the key")
		}
		if keyHeader == "" {
			return "", errors.New("--key needs --key-header, the header to send it in")
		}
		src.KeyEnv, src.Key, src.KeyHeader = r.Arg, os.Getenv(r.Arg), keyHeader
	}
	if weight != "" {
		w, err := strconv.ParseFloat(weight, 64)
		if err != nil || w < 0 {
			return "", errors.New("--weight takes a number of 0 or more")
		}
		src.Weight = w
	}
	report := ""
	if !noCheck {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		p, err := bench.ProbeSource(ctx, sourceFetcher(), src, router.DefaultCatalogJSON())
		if err != nil {
			return "", fmt.Errorf("couldn't read it: %v (nothing was saved; --no-check saves it anyway)", err)
		}
		// Save the fields AFK found, so a change in the data doesn't change
		// which field is read.
		src.Rows, src.Model, src.Score = p.Rows, p.Model, p.Score
		report = probeText(src, p)
	}
	k := "bench.custom." + src.ID + "."
	kv := [][2]string{}
	if src.URL != "" {
		kv = append(kv, [2]string{k + "url", src.URL})
	} else {
		kv = append(kv, [2]string{k + "file", src.File})
	}
	kv = append(kv, [2]string{k + "tasks", strings.Join(src.Tasks, ",")})
	for _, f := range [][2]string{{"name", src.Name}, {"format", src.Format}, {"rows", src.Rows}, {"model", src.Model}, {"score", src.Score}, {"key_header", src.KeyHeader}} {
		if f[1] != "" {
			kv = append(kv, [2]string{k + f[0], f[1]})
		}
	}
	if key != "" {
		kv = append(kv, [2]string{k + "key", key})
	}
	if src.Lower {
		kv = append(kv, [2]string{k + "lower", "true"})
	}
	if weight != "" {
		kv = append(kv, [2]string{k + "weight", weight})
	}
	if _, err := config.SetKeys(paths, kv, false); err != nil {
		return "", err
	}
	return report + "Saved " + src.ID + "; the next afk bench sync blends it in.\n", nil
}

func probeText(s bench.Source, p bench.Probe) string {
	var b strings.Builder
	name := s.Name
	if name == "" {
		name = s.ID
	}
	rows := p.Rows
	if rows == "" {
		rows = "(the whole document)"
	}
	fmt.Fprintf(&b, "%s: %d models listed\n", name, p.Listed)
	fmt.Fprintf(&b, "  rows:   %s\n  model:  %s\n  score:  %s", rows, p.Model, p.Score)
	if s.Lower {
		b.WriteString(" (lower is better)")
	}
	b.WriteString("\n  top:   ")
	for i, r := range p.Top {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, " %s %v", r.Name, r.Value)
	}
	b.WriteString("\n")
	if len(p.Matched) == 0 {
		b.WriteString("  matched none of AFK's models: the board doesn't list them yet, or names them differently\n")
		return b.String()
	}
	ids := make([]string, 0, len(p.Matched))
	for id := range p.Matched {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	fmt.Fprintf(&b, "  matched %d of AFK's models:\n", len(ids))
	for _, id := range ids {
		r := p.Matched[id]
		fmt.Fprintf(&b, "    %-28s #%v  %s (%v)\n", id, r.Rank, r.Name, r.Value)
	}
	return b.String()
}

func sourceFetcher() bench.SourceFetcher {
	if d := os.Getenv("AFK_BENCHMARK_FEED_DIR"); d != "" {
		return bench.DirFetcher{Dir: d}
	}
	return bench.HTTPFetcher{}
}

// benchWeightCmd is afk bench weight <id> <weight> [tasks]: the weight
// goes in bench.weights.<kind>.<id> for each task (default: every task
// the source scores).
func benchWeightCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) < 2 || len(argv) > 3 {
		fmt.Fprintln(stderr, "usage: afk bench weight <source> <weight> [tasks]")
		return 2
	}
	home, _ := os.UserHomeDir()
	st, err := config.Resolve(config.Env{Home: home, Getenv: os.Getenv})
	if err != nil {
		fmt.Fprintln(stderr, "afk bench weight:", err)
		return 1
	}
	msg, err := setBenchWeight(config.PathsFor(home, os.Getenv), benchSourceList(st, os.Getenv), argv)
	if err != nil {
		fmt.Fprintln(stderr, "afk bench weight:", err)
		return 1
	}
	fmt.Fprintln(stdout, msg)
	return 0
}

func setBenchWeight(paths config.Paths, list []bench.Source, argv []string) (string, error) {
	id := argv[0]
	var tasks []string
	if id == "lmarena" {
		tasks = []string{"coding_complex", "coding_review", "architecture", "webdev", "research"}
	} else {
		s, ok := findSource(list, id)
		if !ok {
			return "", fmt.Errorf("no source %s", id)
		}
		tasks = s.Tasks
	}
	w, err := strconv.ParseFloat(argv[1], 64)
	if err != nil || w < 0 {
		return "", errors.New("a weight is a number of 0 or more (0 leaves the source out)")
	}
	if len(argv) == 3 {
		if tasks, err = parseTasks(argv[2]); err != nil {
			return "", err
		}
	}
	var kv [][2]string
	for _, t := range tasks {
		kv = append(kv, [2]string{"bench.weights." + t + "." + id, argv[1]})
	}
	if _, err := config.SetKeys(paths, kv, false); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s weighs %s for %s; the next afk bench sync uses it.", id, strconv.FormatFloat(w, 'f', -1, 64), strings.Join(tasks, ", ")), nil
}
