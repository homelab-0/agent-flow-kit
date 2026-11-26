package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	toml "github.com/pelletier/go-toml/v2"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
)

const configUsage = `afk config — your settings, in config.toml

  afk config path [--json]                 where AFK keeps its files
  afk config get [key] [--json]            a value (or the whole file)
  afk config set <key> <value> [--dry-run] [--json]
                                           change one value; comments and
                                           order in the file are kept
  afk config edit                          open config.toml in $VISUAL/$EDITOR
  afk config migrate [--dry-run] [--json]  write config.toml from router.json
                                           and AFK_* variables (shows a diff;
                                           the old files are kept)

Example: afk config set route.prefer cheap
Lists take commas: afk config set trust.repos ~/src/app,~/src/api
Secrets are references, never values: key = "env:LITELLM_KEY".
`

type configFlags struct {
	json, dryRun bool
	args         []string
}

func parseConfigFlags(argv []string) (configFlags, error) {
	var f configFlags
	for i, a := range argv {
		switch {
		case a == "--json":
			f.json = true
		case a == "--dry-run":
			f.dryRun = true
		case a == "--":
			f.args = append(f.args, argv[i+1:]...)
			return f, nil
		case strings.HasPrefix(a, "-") && len(a) > 1:
			return f, fmt.Errorf("unknown option %s", a)
		default:
			f.args = append(f.args, a)
		}
	}
	return f, nil
}

func configEnv() config.Env {
	home, _ := os.UserHomeDir()
	cwd, _ := os.Getwd()
	return config.Env{Home: home, Getenv: os.Getenv, Repo: cwd}
}

func configCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) == 0 || argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help" {
		fmt.Fprint(stdout, configUsage)
		return 0
	}
	f, err := parseConfigFlags(argv[1:])
	if err != nil {
		fmt.Fprintln(stderr, "afk config:", err)
		return 2
	}
	e := configEnv()
	paths := config.PathsFor(e.Home, e.Getenv)
	fail := func(err error) int {
		fmt.Fprintln(stderr, "afk config:", err)
		return 1
	}
	switch argv[0] {
	case "path":
		return configPath(paths, f, stdout)
	case "get":
		return configGet(paths, f, stdout, stderr)
	case "set":
		if len(f.args) != 2 {
			fmt.Fprintln(stderr, "afk config set: needs a key and a value (afk config set route.prefer cheap)")
			return 2
		}
		diff, err := config.SetKey(paths, f.args[0], f.args[1], f.dryRun)
		if err != nil {
			return fail(err)
		}
		if f.json {
			out, _ := json.Marshal(map[string]any{"path": paths.Config, "key": f.args[0], "dry_run": f.dryRun, "diff": diff})
			fmt.Fprintln(stdout, string(out))
			return 0
		}
		fmt.Fprint(stdout, diff)
		if f.dryRun {
			fmt.Fprintln(stdout, "(dry run: nothing written)")
		}
		return 0
	case "edit":
		if f.dryRun || f.json {
			fmt.Fprintln(stderr, "afk config edit: takes no options; use afk config set --dry-run to preview a change")
			return 2
		}
		if err := configEdit(paths, stdout, stderr); err != nil {
			return fail(err)
		}
		return 0
	case "migrate":
		m, err := config.PlanMigration(e)
		if err != nil {
			return fail(err)
		}
		if f.json {
			out, _ := json.Marshal(struct {
				*config.Migration
				DryRun bool `json:"dry_run"`
			}{m, f.dryRun})
			fmt.Fprintln(stdout, string(out))
		} else {
			printMigration(m, f.dryRun, stdout)
		}
		if f.dryRun {
			return 0
		}
		if err := m.Apply(); err != nil {
			return fail(err)
		}
		return 0
	}
	fmt.Fprintf(stderr, "afk config: unknown command %s (see afk config --help)\n", argv[0])
	return 2
}

func configPath(p config.Paths, f configFlags, stdout io.Writer) int {
	exists := func(path string) bool { _, err := os.Stat(path); return err == nil }
	if f.json {
		out, _ := json.Marshal(map[string]any{
			"config": p.Config, "config_exists": exists(p.Config),
			"lock": p.Lock, "lock_exists": exists(p.Lock),
			"state":  p.State,
			"legacy": p.Legacy, "legacy_exists": exists(p.Legacy),
		})
		fmt.Fprintln(stdout, string(out))
		return 0
	}
	mark := func(path string) string {
		if exists(path) {
			return ""
		}
		return "  (not there yet)"
	}
	fmt.Fprintf(stdout, "config  %s%s\nlock    %s%s\nstate   %s\n", p.Config, mark(p.Config), p.Lock, mark(p.Lock), p.State)
	if exists(p.Legacy) {
		note := "read while config.toml is absent; afk config migrate copies it"
		if exists(p.Config) {
			note = "no longer read: config.toml is there"
		}
		fmt.Fprintf(stdout, "old     %s  (%s)\n", p.Legacy, note)
	}
	return 0
}

func configGet(p config.Paths, f configFlags, stdout, stderr io.Writer) int {
	file, err := config.Load(p.Config)
	if err != nil {
		fmt.Fprintln(stderr, "afk config:", err)
		return 1
	}
	for _, w := range file.Warnings {
		fmt.Fprintln(stderr, "afk: warning:", w)
	}
	if len(f.args) > 1 {
		fmt.Fprintln(stderr, "afk config get: one key at a time")
		return 2
	}
	if len(f.args) == 0 {
		if f.json {
			var m map[string]any
			if file.Exists {
				_ = toml.Unmarshal(file.Raw, &m)
			}
			return printJSON(stdout, stderr, map[string]any{"path": p.Config, "exists": file.Exists, "config": m})
		}
		if !file.Exists {
			fmt.Fprintf(stdout, "# %s doesn't exist yet: AFK is using its defaults", p.Config)
			if _, err := os.Stat(p.Legacy); err == nil {
				fmt.Fprintf(stdout, " and %s", p.Legacy)
			}
			fmt.Fprintln(stdout, ".")
			return 0
		}
		_, _ = stdout.Write(file.Raw)
		return 0
	}
	key := f.args[0]
	v, set, err := file.Get(key)
	if err != nil {
		fmt.Fprintln(stderr, "afk config:", err)
		return 2
	}
	source := "config.toml"
	if !set {
		source = "default"
		if v == nil {
			source = "unset"
		}
	}
	if f.json {
		return printJSON(stdout, stderr, map[string]any{"key": key, "value": v, "source": source})
	}
	switch x := v.(type) {
	case nil:
		fmt.Fprintf(stderr, "afk config: %s is not set\n", key)
		return 1
	case map[string]any:
		b, _ := toml.Marshal(x)
		_, _ = stdout.Write(b)
	case []any:
		var s []string
		for _, i := range x {
			s = append(s, fmt.Sprint(i))
		}
		fmt.Fprintln(stdout, strings.Join(s, ","))
	default:
		fmt.Fprintln(stdout, x)
	}
	return 0
}

func printMigration(m *config.Migration, dryRun bool, stdout io.Writer) {
	if len(m.Changes) == 0 && m.Exists {
		fmt.Fprintln(stdout, "Nothing to migrate: config.toml already has everything the old settings set.")
	} else if m.Diff != "" {
		fmt.Fprint(stdout, m.Diff)
	}
	for _, c := range m.Changes {
		fmt.Fprintf(stdout, "  %s = %s  (from %s)\n", c.Key, c.Value, c.From)
	}
	sort.Strings(m.Kept)
	for _, k := range m.Kept {
		fmt.Fprintf(stdout, "  kept %s: config.toml already sets it\n", k)
	}
	for _, s := range m.Skipped {
		fmt.Fprintf(stdout, "  skipped %s\n", s)
	}
	switch {
	case dryRun:
		fmt.Fprintln(stdout, "(dry run: nothing written)")
	case len(m.Changes) > 0 || !m.Exists:
		fmt.Fprintf(stdout, "Wrote %s. The old files are untouched; while config.toml exists, router.json is no longer read.\n", m.Path)
	}
}

// configEdit opens a copy of config.toml in the editor and saves it only
// if it validates, so a typo never leaves a broken file in place.
func configEdit(p config.Paths, stdout, stderr io.Writer) error {
	editor := os.Getenv("VISUAL")
	if editor == "" {
		editor = os.Getenv("EDITOR")
	}
	if editor == "" {
		editor = "vi"
	}
	cur, err := os.ReadFile(p.Config)
	base := cur // what the file held; nil when it doesn't exist yet
	if errors.Is(err, os.ErrNotExist) {
		if _, lerr := os.Stat(p.Legacy); lerr == nil {
			return fmt.Errorf("%s holds your current settings and stops being read once config.toml exists; run afk config migrate first", p.Legacy)
		}
		cur, base, err = []byte(config.Template), nil, nil
	}
	if err != nil {
		return err
	}
	if err := os.MkdirAll(p.Dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(p.Dir, "config.*.toml")
	if err != nil {
		return err
	}
	name := tmp.Name()
	// A copy that didn't write in full must never reach the editor: saving
	// it would drop the rest of your settings.
	if _, err := tmp.Write(cur); err != nil {
		tmp.Close()
		os.Remove(name)
		return fmt.Errorf("could not make the copy to edit: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return fmt.Errorf("could not make the copy to edit: %w", err)
	}
	words := strings.Fields(editor)
	cmd := exec.Command(words[0], append(words[1:], name)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("the editor failed (%v); your edits are in %s", err, name)
	}
	edited, err := os.ReadFile(name)
	if err != nil {
		return err
	}
	f, err := config.Parse(p.Config, edited)
	if err != nil {
		return fmt.Errorf("not saved, the file doesn't validate:\n%v\nyour edits are in %s", err, name)
	}
	for _, w := range f.Warnings {
		fmt.Fprintln(stderr, "afk: warning:", w)
	}
	if string(edited) == string(cur) {
		os.Remove(name)
		fmt.Fprintln(stdout, "No changes.")
		return nil
	}
	if err := config.WriteConfig(p.Config, base, edited); err != nil {
		return fmt.Errorf("%v; your edits are in %s", err, name)
	}
	os.Remove(name)
	fmt.Fprintf(stdout, "Saved %s.\n", filepath.Clean(p.Config))
	return nil
}

// printJSON writes one JSON line. A value JSON can't hold (a TOML nan or
// inf in an unknown key) is an error, not an empty line.
func printJSON(stdout, stderr io.Writer, v any) int {
	b, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintln(stderr, "afk config: can't write that as JSON:", err)
		return 1
	}
	fmt.Fprintln(stdout, string(b))
	return 0
}
