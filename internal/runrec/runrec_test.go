package runrec

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

func TestWriteRecord(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	dir, err := Dir()
	if err != nil {
		t.Fatal(err)
	}
	id, err := Reserve(dir)
	if err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(filepath.Join(dir, id+".json")); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("the id is claimed on disk at once: %v", err)
	}
	if !regexp.MustCompile(`^r-[0-9a-f]{4}$`).MatchString(id) {
		t.Errorf("id %q", id)
	}
	var r engine.Route
	_ = json.Unmarshal([]byte(`{"harness":"claude","model":"m","effective_score":78.1}`), &r)
	files, before := 3, 78
	solved := Solved
	path, err := Write(dir, Record{ID: id, Where: "here", Route: r, Exit: 0, DurationS: 1421, PoolBefore: &before, FilesChanged: &files, Outcome: &solved})
	if err != nil {
		t.Fatal(err)
	}
	if path != filepath.Join(dir, id+".json") {
		t.Errorf("path %s", path)
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	b, _ := os.ReadFile(path)
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got["schema"] != "afk-run/1" || got["outcome"] != "solved" || got["pool_after"] != nil || got["commits"] != nil ||
		got["route"].(map[string]any)["effective_score"] != 78.1 || got["duration_s"] != 1421.0 {
		t.Errorf("record %s", b)
	}
	for _, k := range []string{"id", "started_at", "ended_at", "where", "route", "exit", "duration_s", "pool_before", "pool_after", "files_changed", "commits", "outcome"} {
		if _, ok := got[k]; !ok {
			t.Errorf("record lacks %s", k)
		}
	}
	seen := map[string]bool{id: true}
	for i := 0; i < 50; i++ {
		n, err := Reserve(dir)
		if err != nil || seen[n] {
			t.Fatalf("reserve %d: %q %v", i, n, err)
		}
		seen[n] = true
	}
}

func TestLoadSkipsPlaceholdersOldAndForeignRecords(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	if _, err := Reserve(dir); err != nil { // an empty placeholder
		t.Fatal(err)
	}
	if _, err := Write(dir, Record{ID: "r-new1", EndedAt: Stamp(now)}); err != nil {
		t.Fatal(err)
	}
	if _, err := Write(dir, Record{ID: "r-old1", EndedAt: Stamp(now.Add(-400 * 24 * time.Hour))}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "r-other.json"), []byte(`{"schema":"afk-run/9"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got := Load(dir, now.Add(-180*24*time.Hour))
	if len(got) != 1 || got[0].ID != "r-new1" {
		t.Fatalf("loaded %+v", got)
	}
	if Load(filepath.Join(dir, "missing"), now) != nil {
		t.Error("a missing dir should be no records")
	}
}
