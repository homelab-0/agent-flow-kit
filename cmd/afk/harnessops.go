package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/x/term"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
	"github.com/jlengelbrecht/agent-flow-kit/internal/launch"
)

const harnessOpsHelp = `
  afk harness doctor [name] [--json]        check each installed CLI: version,
                                            sign-in (its own status command,
                                            exit code only) and its mode flags
  afk harness login <name> [--device]       run the CLI's own sign-in in this
                                            terminal, then check it worked
  afk harness add <name> [--version V] [-y] [--dry-run] [--json]
                                            install it with the vendor's npm
                                            package, pinned, and record it in
                                            afk.lock
  afk harness update <name> [-y] [--dry-run] [--json]
                                            update it the way it was installed
  afk harness remove <name> [-y] [--dry-run] [--json]
                                            remove a CLI that AFK installed

add, update and remove show the command first and ask once; -y skips the
question. AFK never sees a password or token: a CLI's sign-in is its own.
`

// hops is how the harness commands reach the machine. Tests replace it.
type hops struct {
	env harness.Env
	// run runs a command with its output captured.
	run func(ctx context.Context, argv []string) (out []byte, exit int, err error)
	// tty runs a command in this terminal, for a sign-in.
	tty func(argv []string) (exit int, err error)
	// confirm asks a yes/no question; isTTY says whether anyone can answer.
	confirm func(q string) bool
	isTTY   bool
	lock    string
	now     func() time.Time
}

func hostOps() hops {
	home, _ := os.UserHomeDir()
	tty := term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd())
	in := bufio.NewReader(os.Stdin)
	return hops{
		env: harness.HostEnv(),
		run: func(ctx context.Context, argv []string) ([]byte, int, error) {
			ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
			defer cancel()
			cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
			var out bytes.Buffer
			cmd.Stdout, cmd.Stderr = &out, &out
			err := cmd.Run()
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				return out.Bytes(), ee.ExitCode(), nil
			}
			if err != nil {
				return out.Bytes(), 127, err
			}
			return out.Bytes(), 0, nil
		},
		tty: func(argv []string) (int, error) {
			bin, err := exec.LookPath(argv[0])
			if err != nil {
				return 127, err
			}
			res, err := launch.Run(launch.Spec{Argv: append([]string{bin}, argv[1:]...), Env: os.Environ(), TTY: os.Stdin})
			return res.ExitCode, err
		},
		confirm: func(q string) bool {
			fmt.Fprint(os.Stdout, q+" [y/N] ")
			ans, _ := in.ReadString('\n')
			ans = strings.ToLower(strings.TrimSpace(ans))
			return ans == "y" || ans == "yes"
		},
		isTTY: tty,
		lock:  config.PathsFor(home, os.Getenv).Lock,
		now:   time.Now,
	}
}

type hflags struct {
	json, yes, dryRun, device bool
	version                   string
	args                      []string
}

func parseHFlags(argv []string) (hflags, error) {
	var f hflags
	for i := 0; i < len(argv); i++ {
		switch a := argv[i]; {
		case a == "--json":
			f.json = true
		case a == "-y" || a == "--yes":
			f.yes = true
		case a == "--dry-run":
			f.dryRun = true
		case a == "--device":
			f.device = true
		case a == "--version":
			if i+1 >= len(argv) {
				return f, errors.New("--version needs a version")
			}
			f.version = argv[i+1]
			i++
		case strings.HasPrefix(a, "--version="):
			f.version = strings.TrimPrefix(a, "--version=")
		case strings.HasPrefix(a, "-"):
			return f, fmt.Errorf("unknown option %s", a)
		default:
			f.args = append(f.args, a)
		}
	}
	return f, nil
}

// harnessOp runs a harness subcommand other than list.
func harnessOp(o hops, verb string, argv []string, stdout, stderr io.Writer) int {
	f, err := parseHFlags(argv)
	if err != nil {
		fmt.Fprintln(stderr, "afk harness:", err)
		return 2
	}
	fail := func(code int, format string, a ...any) int {
		fmt.Fprintf(stderr, "afk harness "+verb+": "+format+"\n", a...)
		return code
	}
	needOne := func() (harness.Adapter, bool) {
		if len(f.args) != 1 {
			return harness.Adapter{}, false
		}
		a, ok := harness.Lookup(f.args[0])
		return a, ok
	}
	ctx := context.Background()
	switch verb {
	case "doctor":
		return doctor(o, f, stdout, stderr)
	case "login":
		a, ok := needOne()
		if !ok {
			return fail(2, "needs the name of a CLI AFK knows (afk harness --all)")
		}
		return login(o, a, f, stdout, stderr)
	case "add", "update", "remove":
		a, ok := needOne()
		if !ok {
			return fail(2, "needs the name of a CLI AFK knows (afk harness --all)")
		}
		in := harness.Inspect(ctx, o.env, a, harness.Options{})
		var p *plan
		switch verb {
		case "add":
			p, err = planAdd(ctx, o, a, in, f.version)
		case "update":
			p, err = planUpdate(ctx, o, a, in)
		default:
			p, err = planRemove(o, a, in)
		}
		if err != nil {
			return fail(1, "%v", err)
		}
		return carryOut(ctx, o, p, f, stdout, stderr)
	}
	return fail(2, "unknown command (see afk harness --help)")
}

// plan is a change to the machine, shown before it is made.
type plan struct {
	Verb      string   `json:"verb"`
	Harness   string   `json:"harness"`
	Command   []string `json:"command"`
	Version   string   `json:"version,omitempty"`
	Source    string   `json:"source,omitempty"`
	Integrity string   `json:"integrity,omitempty"`
	// Scripts are the package's install scripts, which run on install.
	Scripts []string `json:"install_scripts,omitempty"`
	Notes   []string `json:"notes,omitempty"`
	// lock is what happens to afk.lock afterwards.
	record *config.Install
	drop   bool
}

// npmVersion pins a package version and reads what npm says about it.
func npmVersion(ctx context.Context, o hops, pkg, want string) (version, integrity string, scripts []string, err error) {
	if want == "" {
		want = "latest"
	}
	out, code, err := o.run(ctx, []string{"npm", "view", pkg + "@" + want, "version", "dist.integrity", "scripts", "--json"})
	if err != nil || code != 0 {
		return "", "", nil, fmt.Errorf("npm couldn't resolve %s@%s: %s", pkg, want, strings.TrimSpace(firstLines(out, 3)))
	}
	var v struct {
		Version   string            `json:"version"`
		Integrity string            `json:"dist.integrity"`
		Scripts   map[string]string `json:"scripts"`
	}
	if err := json.Unmarshal(out, &v); err != nil || v.Version == "" {
		return "", "", nil, fmt.Errorf("npm's answer for %s@%s wasn't one version (give an exact one with --version)", pkg, want)
	}
	for _, k := range []string{"preinstall", "install", "postinstall"} {
		if s, ok := v.Scripts[k]; ok {
			scripts = append(scripts, k+": "+s)
		}
	}
	return v.Version, v.Integrity, scripts, nil
}

func firstLines(b []byte, n int) string {
	lines := strings.SplitN(string(b), "\n", n+1)
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, " ")
}

func planAdd(ctx context.Context, o hops, a harness.Adapter, in harness.Info, want string) (*plan, error) {
	if in.Installed {
		return nil, fmt.Errorf("%s is already installed (%s); use afk harness update %s", a.Name, in.ResolvedPath, a.Name)
	}
	if a.NPMPackage == "" {
		return nil, fmt.Errorf("%s isn't installed from npm; install it the way its vendor describes, and AFK will find it", a.Name)
	}
	return npmPlan(ctx, o, "add", a, want)
}

func npmPlan(ctx context.Context, o hops, verb string, a harness.Adapter, want string) (*plan, error) {
	ver, integ, scripts, err := npmVersion(ctx, o, a.NPMPackage, want)
	if err != nil {
		return nil, err
	}
	src := "npm:" + a.NPMPackage + "@" + ver
	p := &plan{Verb: verb, Harness: a.Name, Command: []string{"npm", "install", "-g", a.NPMPackage + "@" + ver},
		Version: ver, Source: src, Integrity: integ, Scripts: scripts}
	if want == "" || want == "latest" {
		p.Notes = append(p.Notes, "latest is "+ver+"; that exact version is installed and recorded")
	}
	if integ == "" {
		p.Notes = append(p.Notes, "npm gave no integrity hash, so it can't be recorded in afk.lock")
	} else {
		p.record = &config.Install{Name: a.Name, Kind: "harness", Version: ver, Source: src, Integrity: integ, Harnesses: []string{a.Name}}
	}
	return p, nil
}

func planUpdate(ctx context.Context, o hops, a harness.Adapter, in harness.Info) (*plan, error) {
	if !in.Installed {
		return nil, fmt.Errorf("%s isn't installed; use afk harness add %s", a.Name, a.Name)
	}
	lock, err := config.ReadLock(o.lock)
	if err != nil {
		return nil, err
	}
	ours := lockEntry(lock, a.Name) != nil
	if ours || (in.InstallMethod == "npm" && a.NPMPackage != "") {
		return npmPlan(ctx, o, "update", a, "latest")
	}
	if len(in.UpdateCommand) == 0 {
		return nil, fmt.Errorf("AFK doesn't know how %s was installed here (%s); update it that way", a.Name, in.ResolvedPath)
	}
	return &plan{Verb: "update", Harness: a.Name, Command: in.UpdateCommand,
		Notes: []string{"installed with " + in.InstallMethod + ", so it is updated the same way"}}, nil
}

func planRemove(o hops, a harness.Adapter, in harness.Info) (*plan, error) {
	lock, err := config.ReadLock(o.lock)
	if err != nil {
		return nil, err
	}
	e := lockEntry(lock, a.Name)
	if e == nil {
		how := in.InstallMethod
		if how == "" {
			how = "however it was installed"
		}
		return nil, fmt.Errorf("AFK didn't install %s, so it won't remove it; remove it with %s", a.Name, how)
	}
	return &plan{Verb: "remove", Harness: a.Name, Command: []string{"npm", "uninstall", "-g", a.NPMPackage},
		Version: e.Version, Source: e.Source, drop: true}, nil
}

func lockEntry(l *config.Lock, name string) *config.Install {
	for i, x := range l.Installs {
		if x.Kind == "harness" && x.Name == name {
			return &l.Installs[i]
		}
	}
	return nil
}

// carryOut shows the plan, asks once, runs it and records it.
func carryOut(ctx context.Context, o hops, p *plan, f hflags, stdout, stderr io.Writer) int {
	show := func() {
		fmt.Fprintf(stdout, "afk harness %s %s will run:\n  %s\n", p.Verb, p.Harness, strings.Join(p.Command, " "))
		for _, s := range p.Scripts {
			fmt.Fprintf(stdout, "  the package runs this on install: %s\n", s)
		}
		for _, n := range p.Notes {
			fmt.Fprintf(stdout, "  (%s)\n", n)
		}
	}
	if f.dryRun {
		if f.json {
			return printHJSON(stdout, stderr, map[string]any{"plan": p, "dry_run": true})
		}
		show()
		fmt.Fprintln(stdout, "(dry run: nothing was run)")
		return 0
	}
	if !f.json {
		show()
	}
	if !f.yes {
		if !o.isTTY {
			fmt.Fprintln(stderr, "afk harness: nobody to ask here; run it again with -y to go ahead")
			return 2
		}
		if !o.confirm("Go ahead?") {
			fmt.Fprintln(stdout, "Nothing was changed.")
			return 1
		}
	}
	out, code, err := o.run(ctx, p.Command)
	if err != nil || code != 0 {
		fmt.Fprintf(stderr, "afk harness %s: %s failed (exit %d): %s\n", p.Verb, strings.Join(p.Command, " "), code, strings.TrimSpace(firstLines(out, 6)))
		return 1
	}
	if p.record != nil || p.drop {
		lock, err := config.ReadLock(o.lock)
		if err == nil {
			if p.drop {
				lock.Remove("harness", p.Harness)
			} else {
				r := *p.record
				r.InstalledAt = o.now().UTC()
				lock.Put(r)
			}
			err = config.WriteLock(o.lock, lock)
		}
		if err != nil {
			fmt.Fprintf(stderr, "afk harness %s: done, but afk.lock wasn't updated: %v\n", p.Verb, err)
			return 1
		}
	}
	if f.json {
		return printHJSON(stdout, stderr, map[string]any{"plan": p, "dry_run": false, "done": true})
	}
	fmt.Fprintf(stdout, "Done.")
	if a, ok := harness.Lookup(p.Harness); ok && p.Verb != "remove" && a.Login != "" {
		fmt.Fprintf(stdout, " Sign in with: afk harness login %s", p.Harness)
	}
	fmt.Fprintln(stdout)
	return 0
}

func printHJSON(stdout, stderr io.Writer, v any) int {
	b, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintln(stderr, "afk harness:", err)
		return 1
	}
	fmt.Fprintln(stdout, string(b))
	return 0
}

// statusOf runs a CLI's own sign-in status command. Only the exit code
// counts: wording changes between releases, and the output is dropped.
func statusOf(ctx context.Context, o hops, a harness.Adapter) (checked, signedIn bool) {
	st := a.Manifest.Auth.Status
	if len(st) == 0 {
		return false, false
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, code, err := o.run(ctx, st)
	if err != nil {
		return false, false
	}
	return true, code == 0
}

func login(o hops, a harness.Adapter, f hflags, stdout, stderr io.Writer) int {
	argv := a.Manifest.Auth.Login
	if f.device {
		argv = a.Manifest.Auth.DeviceLogin
		if len(argv) == 0 {
			fmt.Fprintf(stderr, "afk harness login: %s has no sign-in without a browser in its manifest\n", a.Name)
			return 2
		}
	}
	if len(argv) == 0 {
		note := a.Manifest.LoginNote
		if note == "" {
			note = "see its own documentation"
		}
		fmt.Fprintf(stderr, "afk harness login: %s has no sign-in command AFK can run; %s\n", a.Name, note)
		return 2
	}
	if !o.isTTY {
		fmt.Fprintf(stderr, "afk harness login: signing in needs a terminal; run %s yourself\n", strings.Join(argv, " "))
		return 2
	}
	fmt.Fprintf(stdout, "Running %s. Its prompts are its own; AFK sees nothing you type.\n", strings.Join(argv, " "))
	code, err := o.tty(argv)
	if err != nil {
		fmt.Fprintf(stderr, "afk harness login: %v\n", err)
		return 127
	}
	checked, ok := statusOf(context.Background(), o, a)
	switch {
	case checked && ok:
		fmt.Fprintf(stdout, "%s is signed in.\n", a.Name)
		return 0
	case checked:
		fmt.Fprintf(stdout, "%s still reports it isn't signed in (%s exited non-zero).\n", a.Name, strings.Join(a.Manifest.Auth.Status, " "))
		return 1
	}
	if code != 0 {
		fmt.Fprintf(stdout, "%s exited %d.\n", strings.Join(argv, " "), code)
		return 1
	}
	fmt.Fprintf(stdout, "Done. %s has no status command, so AFK can't confirm the sign-in.\n", a.Name)
	return 0
}

// doctorRow is one CLI's check.
type doctorRow struct {
	Name     string   `json:"name"`
	Version  string   `json:"version,omitempty"`
	Verified string   `json:"modes_verified,omitempty"`
	Auth     string   `json:"auth"`
	Status   string   `json:"auth_status"` // signed_in, signed_out, not_checked
	Missing  []string `json:"missing_flags,omitempty"`
	Problems []string `json:"problems,omitempty"`
}

func doctor(o hops, f hflags, stdout, stderr io.Writer) int {
	ctx := context.Background()
	var rows []doctorRow
	for _, a := range harness.All() {
		if len(f.args) > 0 && a.Name != f.args[0] {
			continue
		}
		in := harness.Inspect(ctx, o.env, a, harness.Options{})
		if !in.Installed {
			if len(f.args) > 0 {
				fmt.Fprintf(stderr, "afk harness doctor: %s isn't installed\n", a.Name)
				return 1
			}
			continue
		}
		r := doctorRow{Name: a.Name, Version: in.Version, Verified: a.Manifest.Modes.Verified, Auth: string(in.Auth), Status: "not_checked"}
		if !in.Healthy {
			r.Problems = append(r.Problems, in.Problem)
		}
		if checked, ok := statusOf(ctx, o, a); checked {
			r.Status = map[bool]string{true: "signed_in", false: "signed_out"}[ok]
			if !ok {
				r.Problems = append(r.Problems, "not signed in; run afk harness login "+a.Name)
			}
		}
		if r.Verified != "" && in.Version != "" && !strings.Contains(in.Version, r.Verified) {
			r.Problems = append(r.Problems, "its mode flags were checked against "+r.Verified+", this is "+in.Version)
		}
		r.Missing = missingFlags(ctx, o, in.Binary, a.Manifest)
		if len(r.Missing) > 0 {
			r.Problems = append(r.Problems, "its --help doesn't mention "+strings.Join(r.Missing, ", ")+"; a mode that uses them may fail")
		}
		rows = append(rows, r)
	}
	if rows == nil {
		rows = []doctorRow{}
	}
	if f.json {
		return printHJSON(stdout, stderr, map[string]any{"harnesses": rows})
	}
	if len(rows) == 0 {
		fmt.Fprintln(stdout, "None of the supported CLIs is installed.")
		return 0
	}
	bad := 0
	for _, r := range rows {
		mark := "ok"
		if len(r.Problems) > 0 {
			mark, bad = "!!", bad+1
		}
		fmt.Fprintf(stdout, "%s %-9s %s  sign-in %s", mark, r.Name, r.Version, strings.ReplaceAll(r.Status, "_", " "))
		if r.Verified != "" {
			fmt.Fprintf(stdout, "  modes checked on %s", r.Verified)
		}
		fmt.Fprintln(stdout)
		for _, p := range r.Problems {
			fmt.Fprintln(stdout, "     "+p)
		}
	}
	if bad > 0 {
		return 1
	}
	return 0
}

// missingFlags lists the mode flags a CLI's --help doesn't mention.
func missingFlags(ctx context.Context, o hops, bin string, m harness.Manifest) []string {
	if bin == "" || !m.HasModes() {
		return nil
	}
	out, _, err := o.run(ctx, []string{bin, "--help"})
	if err != nil {
		return nil
	}
	help := string(out)
	seen := map[string]bool{}
	var missing []string
	for _, mode := range harness.PermissionModes {
		flags, _, _, ok := m.ModeFlags(mode, false)
		if !ok {
			continue
		}
		for _, fl := range flags {
			if strings.HasPrefix(fl, "--") && !seen[fl] {
				seen[fl] = true
				if !strings.Contains(help, fl) {
					missing = append(missing, fl)
				}
			}
		}
	}
	return missing
}
