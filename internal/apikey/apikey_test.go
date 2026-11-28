package apikey

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func store(t *testing.T) *Store {
	t.Helper()
	return &Store{Path: filepath.Join(t.TempDir(), "state", "keys.json")}
}

func TestCreateKeepsOnlyAHash(t *testing.T) {
	s := store(t)
	k, token, err := s.Create(New{Name: "gw", Kind: KindRouter})
	if err != nil {
		t.Fatal(err)
	}
	if !LooksLikeKey(token) || k.Limits != DefaultLimits(KindRouter) || k.RunMode() != "read-only" {
		t.Fatalf("key %+v token %q", k, token)
	}
	b, err := os.ReadFile(s.Path)
	if err != nil {
		t.Fatal(err)
	}
	secret := token[strings.LastIndex(token, "_")+1:]
	if strings.Contains(string(b), secret) {
		t.Error("the keys file holds the secret")
	}
	if fi, _ := os.Stat(s.Path); fi.Mode().Perm() != 0o600 {
		t.Errorf("keys file mode %v", fi.Mode().Perm())
	}
	if got, ok := s.Verify(token); !ok || got.Name != "gw" {
		t.Errorf("verify %+v %v", got, ok)
	}
	for _, bad := range []string{"", "afk_", token[:len(token)-1] + "0x", strings.Replace(token, secret, strings.Repeat("0", 64), 1), "sk-" + token} {
		if _, ok := s.Verify(bad); ok {
			t.Errorf("%q verified", bad)
		}
	}
}

func TestRotateRevokeDelete(t *testing.T) {
	s := store(t)
	_, old, err := s.Create(New{Name: "grok", Kind: KindHarness, Harness: "grok"})
	if err != nil {
		t.Fatal(err)
	}
	k, fresh, err := s.Rotate("grok")
	if err != nil || fresh == old || k.Rotated == nil {
		t.Fatalf("rotate %+v %v", k, err)
	}
	if _, ok := s.Verify(old); ok {
		t.Error("the old secret still works after a rotate")
	}
	if _, ok := s.Verify(fresh); !ok {
		t.Error("the new secret doesn't work")
	}
	if _, err := s.Revoke("grok"); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Verify(fresh); ok {
		t.Error("a revoked key works")
	}
	// A rotate brings a revoked key back, with a new secret.
	_, again, err := s.Rotate("grok")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Verify(again); !ok {
		t.Error("a rotated key should work again")
	}
	if err := s.Delete("grok"); err != nil {
		t.Fatal(err)
	}
	if keys, _ := s.List(); len(keys) != 0 {
		t.Errorf("keys %v", keys)
	}
}

func TestCreateRefuses(t *testing.T) {
	s := store(t)
	dir := t.TempDir()
	for name, n := range map[string]New{
		"bad name":              {Name: "My Key", Kind: KindRouter},
		"no kind":               {Name: "a"},
		"router with a harness": {Name: "a", Kind: KindRouter, Harness: "grok"},
		"harness without one":   {Name: "a", Kind: KindHarness},
		"a model like a flag":   {Name: "a", Kind: KindHarness, Harness: "grok", Models: []string{"--yolo"}},
		"edits with no folder":  {Name: "a", Kind: KindRouter, Mode: "edits"},
		"ask mode":              {Name: "a", Kind: KindRouter, Dir: dir, Mode: "ask"},
		"relative folder":       {Name: "a", Kind: KindRouter, Dir: "work", Mode: "edits"},
		"missing folder":        {Name: "a", Kind: KindRouter, Dir: filepath.Join(dir, "nope"), Mode: "edits"},
		"negative limit":        {Name: "a", Kind: KindRouter, Limits: &Limits{PerMinute: -1}},
	} {
		if _, _, err := s.Create(n); err == nil {
			t.Errorf("%s: made", name)
		}
	}
	if _, _, err := s.Create(New{Name: "a", Kind: KindRouter, Dir: dir, Mode: "edits"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Create(New{Name: "a", Kind: KindRouter}); err == nil {
		t.Error("two keys with one name")
	}
}

func TestLimiter(t *testing.T) {
	now := time.Unix(1764158400, 0)
	l := &Limiter{Now: func() time.Time { return now }}
	k := Key{Name: "k", Limits: Limits{PerMinute: 2, PerDay: 3, Concurrent: 1}}

	rel, d := l.Acquire(k)
	if d != nil {
		t.Fatal(d)
	}
	if _, d := l.Acquire(k); d == nil || d.Limit != "concurrent" {
		t.Fatalf("a second run at once: %+v", d)
	}
	rel()
	rel() // releasing twice frees one slot only
	rel2, d := l.Acquire(k)
	if d != nil {
		t.Fatal(d)
	}
	rel2()
	if _, d := l.Acquire(k); d == nil || d.Limit != "per_minute" || d.RetryAfter != time.Minute {
		t.Fatalf("a third call in a minute: %+v", d)
	}
	now = now.Add(61 * time.Second)
	rel3, d := l.Acquire(k)
	if d != nil {
		t.Fatal(d)
	}
	rel3()
	now = now.Add(2 * time.Minute)
	if _, d := l.Acquire(k); d == nil || d.Limit != "per_day" || d.RetryAfter < 23*time.Hour {
		t.Fatalf("a fourth call in a day: %+v", d)
	}
	if m, day, active := l.Counts("k"); m != 0 || day != 3 || active != 0 {
		t.Errorf("counts %d %d %d", m, day, active)
	}
	now = now.Add(24 * time.Hour)
	if _, d := l.Acquire(k); d != nil {
		t.Fatalf("after a day: %+v", d)
	}

	// Limits off let everything through; another key has its own counts.
	free := Key{Name: "free"}
	for range 50 {
		if _, d := l.Acquire(free); d != nil {
			t.Fatal(d)
		}
	}
	// Seeded calls count toward the day.
	l.Seed("old", []time.Time{now.Add(-time.Hour), now.Add(-25 * time.Hour), now.Add(-2 * time.Hour)})
	if _, d := l.Acquire(Key{Name: "old", Limits: Limits{PerDay: 2}}); d == nil || d.Limit != "per_day" {
		t.Fatalf("seeded day: %+v", d)
	}
}
