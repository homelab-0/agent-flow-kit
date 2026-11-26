package gitstat

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}

func write(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestOutsideRepo(t *testing.T) {
	s := Take(t.TempDir())
	if s.OK() {
		t.Fatal("not a repository")
	}
	if ch := s.Since(); ch.Files != nil || ch.Commits != nil {
		t.Errorf("outside a repository nothing is known: %+v", ch)
	}
}

func TestSession(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	dir := t.TempDir()
	gitIn(t, dir, "init", "-q")
	write(t, dir, "a", "1")
	write(t, dir, "b", "1")
	write(t, dir, "dirty", "before")
	gitIn(t, dir, "add", "a", "b")
	gitIn(t, dir, "commit", "-qm", "base")
	write(t, dir, "same", "dirty and untouched")

	s := Take(dir)
	if !s.OK() {
		t.Fatal("snapshot of a repository")
	}
	// The session: edits a, commits it, edits the already dirty file, adds c.
	write(t, dir, "a", "2")
	gitIn(t, dir, "commit", "-qam", "one")
	write(t, dir, "dirty", "after")
	write(t, dir, "c", "new")
	ch := s.Since()
	if ch.Commits == nil || *ch.Commits != 1 {
		t.Errorf("commits %v", ch.Commits)
	}
	if ch.Files == nil || *ch.Files != 3 {
		t.Errorf("files %v (a, dirty, c; not b or same)", deref(ch.Files))
	}
}

// A session started in a subdirectory still sees changes to files that were
// already dirty: git status names paths from the top of the work tree.
func TestSessionFromSubdir(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	dir := t.TempDir()
	sub := filepath.Join(dir, "pkg", "inner")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q")
	write(t, dir, "top", "1")
	write(t, sub, "f", "1")
	gitIn(t, dir, "add", ".")
	gitIn(t, dir, "commit", "-qm", "base")
	write(t, sub, "f", "dirty before")
	write(t, dir, "top", "dirty before, untouched")

	s := Take(sub)
	if !s.OK() {
		t.Fatal("snapshot of a repository from a subdirectory")
	}
	write(t, sub, "f", "changed again")
	ch := s.Since()
	if ch.Files == nil || *ch.Files != 1 {
		t.Errorf("files %v (pkg/inner/f only)", deref(ch.Files))
	}
}

func deref(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}
