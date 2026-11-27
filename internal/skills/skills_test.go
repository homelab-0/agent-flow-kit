package skills

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

type fixture struct {
	e       Env
	targets []Target
	root    string
}

func setup(t *testing.T) fixture {
	t.Helper()
	root := t.TempDir()
	f := fixture{root: root, e: Env{
		Central: filepath.Join(root, "afk", "skills"),
		State:   filepath.Join(root, "afk", "state", "skills.json"),
		Now:     func() time.Time { return time.Date(2026, 11, 27, 3, 0, 0, 0, time.UTC) },
	}}
	for _, h := range []string{"claude", "codex"} {
		f.targets = append(f.targets, Target{Harness: h, Dir: filepath.Join(root, h, "skills")})
	}
	return f
}

func write(t *testing.T, p, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (f fixture) cells(t *testing.T) map[string]Cell {
	t.Helper()
	s, err := f.e.Scan(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]Cell{}
	for _, sk := range s.Skills {
		for h, c := range sk.Cells {
			out[h+"/"+sk.Name] = c
		}
	}
	return out
}

func (f fixture) sync(t *testing.T) *Result {
	t.Helper()
	r, err := f.e.Sync(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestSyncAddsUpdatesAndRemoves(t *testing.T) {
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "humanizer", "SKILL.md"), "v1")
	write(t, filepath.Join(f.e.Central, "humanizer", "scripts", "x.sh"), "echo")
	if c := f.cells(t); c["claude/humanizer"] != Pending || c["codex/humanizer"] != Pending {
		t.Fatalf("before sync: %v", c)
	}
	if r := f.sync(t); len(r.Done) != 2 || r.Backup != "" {
		t.Fatalf("first sync: %+v", r)
	}
	if got := read(t, filepath.Join(f.root, "codex", "skills", "humanizer", "scripts", "x.sh")); got != "echo" {
		t.Errorf("copied %q", got)
	}
	if c := f.cells(t); c["claude/humanizer"] != Synced {
		t.Fatalf("after sync: %v", c)
	}
	// An edit to the central copy goes out, with the old copy backed up.
	write(t, filepath.Join(f.e.Central, "humanizer", "SKILL.md"), "v2")
	r := f.sync(t)
	if len(r.Done) != 2 || r.Done[0].Kind != "update" || r.Backup == "" {
		t.Fatalf("update: %+v", r)
	}
	if read(t, filepath.Join(r.Backup, "claude", "humanizer", "SKILL.md")) != "v1" {
		t.Error("the old copy wasn't backed up")
	}
	// Off for codex: AFK's copy goes; on again, it comes back.
	if err := f.e.SetEnabled("humanizer", "codex", false); err != nil {
		t.Fatal(err)
	}
	if c := f.cells(t); c["codex/humanizer"] != Removing {
		t.Fatalf("off: %v", c)
	}
	f.sync(t)
	if exists(filepath.Join(f.root, "codex", "skills", "humanizer")) {
		t.Error("turned off but still there")
	}
	if c := f.cells(t); c["codex/humanizer"] != Off {
		t.Fatalf("after off: %v", c)
	}
	// Deleted centrally: AFK's copies go.
	os.RemoveAll(filepath.Join(f.e.Central, "humanizer"))
	if c := f.cells(t); c["claude/humanizer"] != Orphan {
		t.Fatalf("orphan: %v", c)
	}
	f.sync(t)
	if exists(filepath.Join(f.root, "claude", "skills", "humanizer")) {
		t.Error("a deleted skill's copy stayed")
	}
	if s, _ := f.e.Scan(f.targets); len(s.Skills) != 0 {
		t.Errorf("gone skill still listed: %+v", s.Skills)
	}
}

func TestYourOwnSkillsAreNeverTouched(t *testing.T) {
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "notes", "SKILL.md"), "central")
	write(t, filepath.Join(f.root, "claude", "skills", "notes", "SKILL.md"), "mine")
	write(t, filepath.Join(f.root, "claude", "skills", "other", "SKILL.md"), "mine too")
	// A hand copy identical to central is taken on, not rewritten.
	write(t, filepath.Join(f.root, "codex", "skills", "notes", "SKILL.md"), "central")
	if c := f.cells(t); c["codex/notes"] != Pending {
		t.Fatalf("identical copy: %v", c)
	}
	if c := f.cells(t); c["claude/notes"] != Conflict {
		t.Fatalf("%v", c)
	}
	f.sync(t)
	if read(t, filepath.Join(f.root, "claude", "skills", "notes", "SKILL.md")) != "mine" || read(t, filepath.Join(f.root, "claude", "skills", "other", "SKILL.md")) != "mine too" {
		t.Error("a skill AFK didn't put there was changed")
	}
	if _, err := f.e.Restore(f.targets, "notes", "claude"); err == nil {
		t.Error("restore replaced your own skill")
	}
	if c := f.cells(t); c["codex/notes"] != Synced {
		t.Fatalf("adopted: %v", c)
	}
}

func TestDriftWaitsForYou(t *testing.T) {
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "triage", "SKILL.md"), "central")
	f.sync(t)
	cp := filepath.Join(f.root, "codex", "skills", "triage", "SKILL.md")
	write(t, cp, "edited in codex")
	write(t, filepath.Join(f.e.Central, "triage", "SKILL.md"), "central v2")
	s, _ := f.e.Scan(f.targets)
	if len(s.Drift) != 1 || s.Drift[0].Harness != "codex" {
		t.Fatalf("drift %+v", s.Drift)
	}
	f.sync(t)
	if read(t, cp) != "edited in codex" {
		t.Fatal("a sync overwrote an edit made in the CLI")
	}
	// Keep codex's: it becomes central, and claude gets it on the next sync.
	r, err := f.e.Keep(f.targets, "triage", "codex")
	if err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(f.e.Central, "triage", "SKILL.md")) != "edited in codex" || read(t, filepath.Join(r.Backup, "central", "triage", "SKILL.md")) != "central v2" {
		t.Error("keep didn't replace central with a backup")
	}
	f.sync(t)
	if read(t, filepath.Join(f.root, "claude", "skills", "triage", "SKILL.md")) != "edited in codex" {
		t.Error("the kept copy didn't reach claude")
	}
	// Restore: central wins over a new edit.
	write(t, cp, "another edit")
	if _, err := f.e.Restore(f.targets, "triage", "codex"); err != nil {
		t.Fatal(err)
	}
	if read(t, cp) != "edited in codex" {
		t.Error("restore didn't put central back")
	}
}

func TestFailedSyncRollsBack(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("file modes")
	}
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "a", "SKILL.md"), "v1")
	f.sync(t)
	write(t, filepath.Join(f.e.Central, "a", "SKILL.md"), "v2")
	// codex's directory can't be written: the claude update must be undone.
	if err := os.Chmod(filepath.Join(f.root, "codex", "skills"), 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(filepath.Join(f.root, "codex", "skills"), 0o755)
	if _, err := f.e.Sync(f.targets); err == nil {
		t.Fatal("the sync claimed success")
	}
	if read(t, filepath.Join(f.root, "claude", "skills", "a", "SKILL.md")) != "v1" {
		t.Error("claude's update wasn't rolled back")
	}
	if c := f.cells(t); c["claude/a"] != Pending {
		t.Errorf("state moved on after a failed sync: %v", c)
	}
}

func TestSymlinksAreNotSynced(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks")
	}
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "s", "SKILL.md"), "x")
	if err := os.Symlink("/etc/passwd", filepath.Join(f.e.Central, "s", "leak")); err != nil {
		t.Fatal(err)
	}
	s, err := f.e.Scan(f.targets)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Problems) == 0 || !strings.Contains(s.Problems[0], "symlink") || len(s.Actions) != 0 {
		t.Errorf("a symlinked skill was planned: %+v", s)
	}
}

func TestNew(t *testing.T) {
	f := setup(t)
	p, err := f.e.New("gh-pr-triage", "")
	if err != nil || !strings.Contains(read(t, p), "name: gh-pr-triage") {
		t.Fatalf("%v", err)
	}
	if _, err := f.e.New("../evil", ""); err == nil {
		t.Error("a path was taken as a name")
	}
	if _, err := f.e.New("gh-pr-triage", ""); err == nil {
		t.Error("New overwrote a skill")
	}
}

func TestDiff(t *testing.T) {
	f := setup(t)
	write(t, filepath.Join(f.e.Central, "d", "SKILL.md"), "a\nb\nc\n")
	f.sync(t)
	write(t, filepath.Join(f.root, "codex", "skills", "d", "SKILL.md"), "a\nB\nc\n")
	write(t, filepath.Join(f.root, "codex", "skills", "d", "extra.md"), "x")
	got, err := f.e.Diff(f.targets, "d", "codex")
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"--- central/d/SKILL.md", "- b\n+ B\n", "only in codex: extra.md"} {
		if !strings.Contains(got, w) {
			t.Errorf("missing %q in\n%s", w, got)
		}
	}
	if n := f.e.Changed(f.targets, "d", "codex"); n != 3 {
		t.Errorf("changed %d", n)
	}
}

func TestProjectScopes(t *testing.T) {
	f := setup(t)
	f.e.Ask = true
	write(t, filepath.Join(f.e.Central, "deploy", "SKILL.md"), "---\nname: deploy\n---\nship it\n")
	// Undecided: nothing is copied, every CLI asks.
	if c := f.cells(t); c["claude/deploy"] != Ask || c["codex/deploy"] != Ask {
		t.Fatalf("undecided cells %v", c)
	}
	if res, err := f.e.Sync(f.targets); err != nil || len(res.Done) != 0 {
		t.Fatalf("an undecided skill was synced: %v %v", res, err)
	}
	// Project: copied into each CLI's folder.
	if err := f.e.SetScope("deploy", ScopeProject); err != nil {
		t.Fatal(err)
	}
	if _, err := f.e.Sync(f.targets); err != nil {
		t.Fatal(err)
	}
	if c := f.cells(t); c["claude/deploy"] != Synced {
		t.Fatalf("project cells %v", c)
	}
	// Global: copied into the central folder; AFK's project copies go.
	global := filepath.Join(f.root, "central")
	if err := f.e.CopyInto("deploy", global); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(global, "deploy", "SKILL.md")) != "---\nname: deploy\n---\nship it\n" {
		t.Error("global copy differs")
	}
	if err := f.e.SetScope("deploy", ScopeGlobal); err != nil {
		t.Fatal(err)
	}
	if c := f.cells(t); c["claude/deploy"] != Orphan {
		t.Fatalf("project copies of a global skill should be removed: %v", c)
	}
	if _, err := f.e.Sync(f.targets); err != nil {
		t.Fatal(err)
	}
	if exists(filepath.Join(f.targets[0].Dir, "deploy")) {
		t.Error("the project copy is still there")
	}
	if c := f.cells(t); c["claude/deploy"] != Global {
		t.Fatalf("global cells %v", c)
	}
	// CopyInto never overwrites a different skill.
	write(t, filepath.Join(global, "other", "SKILL.md"), "mine\n")
	write(t, filepath.Join(f.e.Central, "other", "SKILL.md"), "theirs\n")
	if err := f.e.CopyInto("other", global); err == nil || !strings.Contains(err.Error(), "different skill") {
		t.Errorf("CopyInto over a different skill: %v", err)
	}
	if err := f.e.SetScope("deploy", "everywhere"); err == nil {
		t.Error("a bad scope was accepted")
	}
}
