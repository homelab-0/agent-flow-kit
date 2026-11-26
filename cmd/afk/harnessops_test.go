package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
)

// fakeOps is a machine where nothing real runs: commands are answered from
// a script, and the installed CLIs are stubs that only print a version.
type fakeOps struct {
	t      *testing.T
	bin    string
	ran    [][]string
	answer map[string]func(argv []string) ([]byte, int)
	yes    bool
	tty    bool
}

func newFake(t *testing.T, installed map[string]string) *fakeOps {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	f := &fakeOps{t: t, bin: t.TempDir(), answer: map[string]func([]string) ([]byte, int){}, tty: true}
	for name, help := range installed {
		body := "#!/bin/sh\ncase \"$1\" in --version) echo \"" + name + " 2.1.332\";; --help) echo '" + help + "';; esac\n"
		if err := os.WriteFile(filepath.Join(f.bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

func (f *fakeOps) ops() hops {
	home := f.t.TempDir()
	return hops{
		env: harness.Env{Home: home, Path: f.bin, BinDir: f.bin, OS: runtime.GOOS, Getenv: func(string) string { return "" }},
		run: func(ctx context.Context, argv []string) ([]byte, int, error) {
			f.ran = append(f.ran, argv)
			key := strings.Join(argv[:min(2, len(argv))], " ")
			if a, ok := f.answer[key]; ok {
				out, code := a(argv)
				return out, code, nil
			}
			if strings.HasSuffix(argv[len(argv)-1], "--help") || (len(argv) == 2 && argv[1] == "--help") {
				out, _ := os.ReadFile(argv[0])
				return out, 0, nil
			}
			return nil, 0, nil
		},
		tty: func(argv []string) (int, error) {
			f.ran = append(f.ran, append([]string{"(tty)"}, argv...))
			return 0, nil
		},
		confirm: func(string) bool { return f.yes },
		isTTY:   f.tty,
		lock:    filepath.Join(home, "afk.lock"),
		now:     func() time.Time { return time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC) },
	}
}

func npmView(version string) func([]string) ([]byte, int) {
	return func([]string) ([]byte, int) {
		return []byte(`{"version":"` + version + `","dist.integrity":"sha512-AAAA","scripts":{"postinstall":"node install.cjs","test":"x"}}`), 0
	}
}

func hrun(t *testing.T, o hops, verb string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := harnessOp(o, verb, args, &out, &errb)
	return code, out.String(), errb.String()
}

func TestHarnessAddPinsAndRecords(t *testing.T) {
	f := newFake(t, nil)
	f.answer["npm view"] = npmView("0.71.1")
	o := f.ops()
	// Dry run: shows the pinned command and the install script, runs nothing.
	code, out, _ := hrun(t, o, "add", "gemini", "--dry-run")
	if code != 0 || !strings.Contains(out, "npm install -g @google/gemini-cli@0.71.1") || !strings.Contains(out, "postinstall: node install.cjs") || strings.Contains(out, "test: x") {
		t.Fatalf("dry run: %d %s", code, out)
	}
	for _, r := range f.ran {
		if r[0] == "npm" && r[1] == "install" {
			t.Fatal("a dry run installed")
		}
	}
	// Asked, and no: nothing installed.
	if code, _, _ := hrun(t, o, "add", "gemini"); code != 1 || installed(f) {
		t.Fatal("installed without a yes")
	}
	// --json and asked: the plan goes to stderr before the question,
	// and stdout stays JSON-only.
	if code, out, errs := hrun(t, o, "add", "gemini", "--json"); code != 1 || installed(f) || out != "" ||
		!strings.Contains(errs, "npm install -g @google/gemini-cli@0.71.1") || !strings.Contains(errs, "postinstall: node install.cjs") {
		t.Fatalf("--json ask: %d %q %q", code, out, errs)
	}
	// No terminal and no -y: refused.
	o.isTTY = false
	if code, _, errs := hrun(t, o, "add", "gemini"); code != 2 || !strings.Contains(errs, "-y") || installed(f) {
		t.Fatalf("no terminal: %d %s", code, errs)
	}
	// -y: installed and recorded.
	if code, out, errs := hrun(t, o, "add", "gemini", "-y"); code != 0 || !installed(f) {
		t.Fatalf("-y: %d %s %s", code, out, errs)
	}
	l, err := config.ReadLock(o.lock)
	if err != nil || len(l.Installs) != 1 {
		t.Fatalf("lock: %+v %v", l, err)
	}
	in := l.Installs[0]
	if in.Name != "gemini" || in.Kind != "harness" || in.Version != "0.71.1" || in.Source != "npm:@google/gemini-cli@0.71.1" || in.Integrity != "sha512-AAAA" || in.Harnesses[0] != "gemini" {
		t.Fatalf("recorded %+v", in)
	}
	// A CLI that isn't on npm, or is installed, is refused.
	if code, _, errs := hrun(t, o, "add", "grok", "-y"); code != 1 || !strings.Contains(errs, "isn't installed from npm") {
		t.Fatalf("grok: %d %s", code, errs)
	}
}

func installed(f *fakeOps) bool {
	for _, r := range f.ran {
		if len(r) > 2 && r[0] == "npm" && r[1] == "install" {
			return true
		}
	}
	return false
}

func TestHarnessUpdateAndRemove(t *testing.T) {
	f := newFake(t, map[string]string{"claude": "--permission-mode --dangerously-skip-permissions"})
	f.answer["npm view"] = npmView("2.2.0")
	o := f.ops()
	// Not installed by AFK: updated the way it was installed (a
	// self-managed Claude updates itself).
	if code, out, errs := hrun(t, o, "update", "claude", "-y"); code != 0 || !strings.HasSuffix(strings.Join(f.ran[len(f.ran)-1], " "), "claude update") {
		t.Fatalf("update: %d %s %s %v", code, out, errs, f.ran)
	}
	if code, _, errs := hrun(t, o, "remove", "claude", "-y"); code != 1 || !strings.Contains(errs, "AFK didn't install claude") || !strings.Contains(errs, "remove it with") {
		t.Fatalf("remove: %d %s", code, errs)
	}
	// Recorded in afk.lock: updated with npm, pinned, and removable.
	l := &config.Lock{Installs: []config.Install{{Name: "claude", Kind: "harness", Version: "2.1.332", Source: "npm:@anthropic-ai/claude-code@2.1.332", Integrity: "sha512-BBBB", Harnesses: []string{"claude"}}}}
	if err := config.WriteLock(o.lock, l); err != nil {
		t.Fatal(err)
	}
	if code, out, errs := hrun(t, o, "update", "claude", "-y"); code != 0 || !strings.Contains(out, "@anthropic-ai/claude-code@2.2.0") {
		t.Fatalf("update: %d %s %s", code, out, errs)
	}
	if l, _ := config.ReadLock(o.lock); l.Installs[0].Version != "2.2.0" {
		t.Fatalf("lock not updated: %+v", l.Installs)
	}
	if code, _, errs := hrun(t, o, "remove", "claude", "-y"); code != 0 {
		t.Fatalf("remove: %s", errs)
	}
	last := f.ran[len(f.ran)-1]
	if strings.Join(last, " ") != "npm uninstall -g @anthropic-ai/claude-code" {
		t.Fatalf("ran %v", last)
	}
	if l, _ := config.ReadLock(o.lock); len(l.Installs) != 0 {
		t.Fatalf("still recorded: %+v", l.Installs)
	}
}

func TestHarnessLogin(t *testing.T) {
	f := newFake(t, map[string]string{"codex": ""})
	status := 0
	f.answer["codex login"] = func(argv []string) ([]byte, int) { return []byte("Logged in using ChatGPT"), status }
	o := f.ops()
	code, out, _ := hrun(t, o, "login", "codex")
	if code != 0 || !strings.Contains(out, "codex is signed in") {
		t.Fatalf("%d %s", code, out)
	}
	if got := strings.Join(f.ran[0], " "); got != "(tty) codex login" {
		t.Fatalf("ran %q first", got)
	}
	if code, _, _ := hrun(t, o, "login", "codex", "--device"); code != 0 || strings.Join(f.ran[len(f.ran)-2], " ") != "(tty) codex login --device-auth" {
		t.Fatalf("device login: %v", f.ran)
	}
	status = 1
	if code, out, _ := hrun(t, o, "login", "codex"); code != 1 || !strings.Contains(out, "still reports") {
		t.Fatalf("still signed out: %d %s", code, out)
	}
	if code, _, errs := hrun(t, o, "login", "pi"); code != 2 || !strings.Contains(errs, "/login") {
		t.Fatalf("pi: %d %s", code, errs)
	}
	o.isTTY = false
	if code, _, errs := hrun(t, o, "login", "codex"); code != 2 || !strings.Contains(errs, "needs a terminal") {
		t.Fatalf("no terminal: %d %s", code, errs)
	}
}

func TestHarnessDoctor(t *testing.T) {
	// claude's help lacks --permission-mode; its status command fails.
	f := newFake(t, map[string]string{"claude": "--dangerously-skip-permissions"})
	f.answer["claude auth"] = func([]string) ([]byte, int) { return nil, 1 }
	code, out, _ := hrun(t, f.ops(), "doctor", "--json")
	if code != 1 || !strings.Contains(out, `"missing_flags":["--permission-mode"]`) || !strings.Contains(out, `"auth_status":"signed_out"`) || !strings.Contains(out, "afk harness login claude") {
		t.Fatalf("%d %s", code, out)
	}
	if code, _, _ := hrun(t, f.ops(), "doctor"); code != 1 {
		t.Fatal("a problem should exit 1")
	}
}

func TestRemoveHint(t *testing.T) {
	for _, c := range []struct {
		in   harness.Info
		want string
	}{
		{harness.Info{InstallMethod: "npm", Package: "@openai/codex"}, "npm uninstall -g @openai/codex"},
		{harness.Info{InstallMethod: "homebrew", Package: "opencode"}, "brew uninstall opencode"},
		{harness.Info{InstallMethod: "mise", ResolvedPath: "/x/mise/shims/pi"}, "remove it with mise"},
		{harness.Info{InstallMethod: "self-managed", ResolvedPath: "/home/u/.local/bin/claude"}, "/home/u/.local/bin/claude"},
	} {
		if got := removeHint(c.in); !strings.Contains(got, c.want) {
			t.Errorf("%+v: %q, want %q", c.in, got, c.want)
		}
	}
}
