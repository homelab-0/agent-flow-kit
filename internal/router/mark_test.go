package router

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMarksAreReadBackAsSignals(t *testing.T) {
	path := filepath.Join(t.TempDir(), "afk", "pool-signals.json")
	// Entries written by someone else stay.
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"pools":{"openai-plus":{"used_pct":40,"capacity_5h":30}},"note":"kept"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1764158400, 0)
	if err := MarkPoolDegraded(path, "anthropic-max", "quota: Claude AI usage limit reached", now); err != nil {
		t.Fatal(err)
	}
	if err := MarkPoolDegraded(path, "openai-plus", "401 Unauthorized", now); err != nil {
		t.Fatal(err)
	}
	if err := MarkModelUnavailable(path, "claude-old", "model_not_found", now); err != nil {
		t.Fatal(err)
	}
	if err := MarkPoolDegraded(path, "xai-grok", "stream disconnected", now); err != nil {
		t.Fatal(err)
	}

	s := readSignals(path)
	for pool, wantKind := range map[string]string{"anthropic-max": "quota", "openai-plus": "auth", "xai-grok": "transient"} {
		_, kind, ok := activeSignal(s, pool, 0, now.Unix()+60)
		if !ok || kind != wantKind {
			t.Errorf("%s: active %v kind %q, want %q", pool, ok, kind, wantKind)
		}
	}
	if _, _, ok := activeSignal(s, "xai-grok", 0, now.Unix()+901); ok {
		t.Error("a transient mark should lapse after 15 minutes")
	}
	if _, _, ok := activeSignal(s, "openai-plus", now.Unix()+5, now.Unix()+60); ok {
		t.Error("a sign-in mark should clear when the login is renewed")
	}
	if m := s.Unavailable["claude-old"]; m.TTL != 3600 || m.Reason != "model_not_found" {
		t.Errorf("model mark %+v", m)
	}
	var doc map[string]any
	b, _ := os.ReadFile(path)
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["note"] != "kept" || doc["pools"].(map[string]any)["openai-plus"].(map[string]any)["capacity_5h"] != 30.0 {
		t.Errorf("other entries were lost: %s", b)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode changed to %v", fi.Mode().Perm())
	}
	if _, err := os.Stat(path + ".lock"); !os.IsNotExist(err) {
		t.Error("the lock was left behind")
	}
}

func TestMarkTakesOverAStaleLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pool-signals.json")
	// A lock left by a killed writer, as the bash engine leaves one.
	if err := os.Mkdir(path+".lock", 0o755); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute)
	_ = os.Chtimes(path+".lock", old, old)
	if err := MarkModelUnavailable(path, "m", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if readSignals(path).Unavailable["m"].Reason != "model_unavailable" {
		t.Error("mark not written")
	}
}
