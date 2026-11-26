package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func gitRepo(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	return realDir(dir)
}

func TestTrustRules(t *testing.T) {
	f := newEnv(t)
	f.config(t, "version = 1\n")
	p := f.paths()
	repos := filepath.Join(f.home, "repos")
	a := gitRepo(t, filepath.Join(repos, "me", "app"))
	b := gitRepo(t, filepath.Join(repos, "me", "api"))
	plain := filepath.Join(f.home, "notes")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	// Your home, anything above it, a folder with no repository: refused.
	for _, d := range []string{f.home, filepath.Dir(f.home), "/", plain, filepath.Join(f.home, "nope")} {
		if _, err := TrustAdd(p, f.home, d, false); err == nil {
			t.Errorf("trusted %s", d)
		}
	}
	// A parent folder covers every repository below it.
	ch, err := TrustAdd(p, f.home, repos, false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(ch.Covers, ",") != b+","+a || !ch.Changed {
		t.Fatalf("covers %v", ch.Covers)
	}
	if ch, _ := TrustAdd(p, f.home, repos, false); ch.Changed {
		t.Error("added twice")
	}
	s := resolve(t, f)
	if err := CheckYolo(s, f.home, filepath.Join(a, "sub")); err != nil {
		t.Errorf("a repository under a trusted folder: %v", err)
	}
	// Outside a git repository, never; elsewhere, the exact command.
	if err := CheckYolo(s, f.home, plain); err == nil || !strings.Contains(err.Error(), "git repository") {
		t.Errorf("outside git: %v", err)
	}
	other := gitRepo(t, filepath.Join(f.home, "elsewhere", "x"))
	if err := CheckYolo(s, f.home, other); err == nil || !strings.Contains(err.Error(), "afk trust add "+other) {
		t.Errorf("untrusted: %v", err)
	}
	// A repository at $HOME itself never counts, even when trusted somehow.
	gitRepo(t, f.home)
	if err := CheckYolo(Settings{TrustedDirs: []string{"/"}}, f.home, f.home); err == nil {
		t.Error("yolo with $HOME as the repository")
	}
	if _, err := TrustRemove(p, f.home, repos, false); err != nil {
		t.Fatal(err)
	}
	if err := CheckYolo(resolve(t, f), f.home, a); err == nil {
		t.Error("still trusted after remove")
	}
	if _, err := TrustRemove(p, f.home, repos, false); err == nil {
		t.Error("removed twice")
	}
	// Dry run writes nothing.
	before, _ := os.ReadFile(p.Config)
	if ch, err := TrustAdd(p, f.home, a, true); err != nil || ch.Diff == "" {
		t.Fatalf("dry run: %v", err)
	}
	if after, _ := os.ReadFile(p.Config); string(after) != string(before) {
		t.Error("a dry run wrote config.toml")
	}
}

func TestModeFor(t *testing.T) {
	s := Settings{DefaultMode: "edits", TaskModes: map[string]string{"review": "read-only", "coding": "auto"}}
	for task, want := range map[string]string{"": "edits", "quick": "edits", "review": "read-only", "coding": "auto"} {
		if got := s.ModeFor(task); got != want {
			t.Errorf("%q: %s, want %s", task, got, want)
		}
	}
	s.RepoMode = "ask"
	for task, want := range map[string]string{"quick": "ask", "review": "read-only", "coding": "ask"} {
		if got := s.ModeFor(task); got != want {
			t.Errorf("with the project at ask, %q: %s, want %s", task, got, want)
		}
	}
	s.RepoMode = "yolo"
	if got := s.ModeFor("coding"); got != "auto" {
		t.Errorf("a project loosened the mode: %s", got)
	}
	if got := (Settings{}).ModeFor("x"); got != "ask" {
		t.Errorf("default: %s", got)
	}
}

func TestTrustSubdirAndOverlap(t *testing.T) {
	f := newEnv(t)
	f.config(t, "version = 1\n")
	p := f.paths()
	repos := filepath.Join(f.home, "repos")
	a := gitRepo(t, filepath.Join(repos, "app"))
	sub := filepath.Join(a, "src")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	// Trusting a directory inside a repository trusts the repository,
	// so yolo then runs there.
	ch, err := TrustAdd(p, f.home, sub, false)
	if err != nil || ch.Dir != a || strings.Join(ch.Repos, ",") != a {
		t.Fatalf("subdir: %+v %v", ch, err)
	}
	if err := CheckYolo(resolve(t, f), f.home, sub); err != nil {
		t.Fatalf("yolo in the trusted subdir: %v", err)
	}
	// The same argument removes it again.
	if ch, err := TrustRemove(p, f.home, sub, false); err != nil || ch.Dir != a || len(ch.Repos) != 0 {
		t.Fatalf("remove by subdir: %+v %v", ch, err)
	}
	if _, err := TrustAdd(p, f.home, sub, false); err != nil {
		t.Fatal(err)
	}
	// Removing an entry a parent still covers says yolo stays allowed.
	if _, err := TrustAdd(p, f.home, repos, false); err != nil {
		t.Fatal(err)
	}
	ch, err = TrustRemove(p, f.home, a, false)
	if err != nil || strings.Join(ch.StillTrustedBy, ",") != repos {
		t.Fatalf("overlap: %+v %v", ch, err)
	}
}

func TestRelativeTrustRejected(t *testing.T) {
	for _, v := range []string{`""`, `"."`, `"repos/app"`} {
		_, err := Parse("config.toml", []byte("version = 1\n\n[trust]\nrepos = ["+v+"]\n"))
		if err == nil || !strings.Contains(err.Error(), "trust.repos") {
			t.Errorf("%s: %v", v, err)
		}
	}
	for _, v := range []string{`"~"`, `"~/repos"`, `"/src"`} {
		if _, err := Parse("config.toml", []byte("version = 1\n\n[trust]\nrepos = ["+v+"]\n")); err != nil {
			t.Errorf("%s: %v", v, err)
		}
	}
}

func TestWithinWholeComponents(t *testing.T) {
	for _, c := range []struct {
		p, dir string
		want   bool
	}{
		{"/w/..app", "/w", true},
		{"/w", "/w/..me", false},
		{"/w/a", "/w", true},
		{"/w", "/w/a", false},
		{"/w", "/w", true},
	} {
		if got := within(c.p, c.dir); got != c.want {
			t.Errorf("within(%s, %s) = %v", c.p, c.dir, got)
		}
	}
}

func TestFailoverSettingIsYours(t *testing.T) {
	home := t.TempDir()
	repo := t.TempDir()
	env := map[string]string{}
	e := Env{Home: home, Repo: repo, Getenv: func(k string) string { return env[k] }}
	load := func() Settings {
		t.Helper()
		s, err := Resolve(e)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	if s := load(); s.Failover != "any" {
		t.Fatalf("default %q", s.Failover)
	}
	cfg := PathsFor(home, e.Getenv).Config
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg, []byte("version = 1\n[route]\nfailover = \"same-pool\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := load(); s.Failover != "same-pool" {
		t.Fatalf("config %q", s.Failover)
	}
	// A repository can't change it.
	if err := os.MkdirAll(filepath.Join(repo, ".afk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".afk", "config.json"), []byte(`{"route":{"failover":"any"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if s := load(); s.Failover != "same-pool" || len(s.Warnings) == 0 {
		t.Fatalf("repo: %q %v", s.Failover, s.Warnings)
	}
	// The environment wins; a value it doesn't know is ignored.
	env["AFK_ROUTER_FAILOVER"] = "none"
	if s := load(); s.Failover != "none" {
		t.Fatalf("env %q", s.Failover)
	}
	env["AFK_ROUTER_FAILOVER"] = "sometimes"
	if s := load(); s.Failover != "same-pool" {
		t.Fatalf("bad env %q", s.Failover)
	}
}
