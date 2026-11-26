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
