package core

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

// An agy that answers /usage as a prompt is asked once. The record of
// that outlives the cache's few minutes, on disk, for as long as the
// binary is the same.
func TestAUsageCommandThatSpentATurnIsNeverRunAgain(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	home, bin := t.TempDir(), t.TempDir()
	log := filepath.Join(bin, "calls")
	script := "#!/bin/sh\necho \"$*\" >> \"" + log + "\"\ncase \"$1\" in\n--version) echo 1.5.19;;\nmodels) printf 'gemini-4-hydrogen-high\\tx\\n';;\n-p) echo '{\"conversation_id\":\"c1\",\"num_turns\":1}';;\nesac\n"
	if err := os.WriteFile(filepath.Join(bin, "agy"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	mk := func() *Core {
		return &Core{Home: home, Live: true, Now: func() time.Time { return now }, Harness: harness.Env{Home: home, BinDir: bin}}
	}
	usageCalls := func() int {
		b, _ := os.ReadFile(log)
		return strings.Count(string(b), "/usage")
	}
	a, ok := mk().account(nil, true)(context.Background(), "agy")
	if !ok || !a.UsageCommandSpent || usageCalls() != 1 {
		t.Fatalf("first report %+v, %d usage calls", a, usageCalls())
	}
	// Long after the cache went stale, in a new process.
	now = now.Add(48 * time.Hour)
	a, ok = mk().account(nil, true)(context.Background(), "agy")
	if !ok || !a.UsageCommandSpent || !a.ModelsKnown || usageCalls() != 1 {
		t.Errorf("later report %+v, %d usage calls (want still 1)", a, usageCalls())
	}
}

// Switching a CLI's vendor usage lookup makes its cached report stale,
// so the switch takes effect at once in both directions.
func TestTheVendorSwitchIsPartOfTheCache(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	home, bin := t.TempDir(), t.TempDir()
	log := filepath.Join(bin, "calls")
	if err := os.WriteFile(filepath.Join(bin, "opencode"), []byte("#!/bin/sh\necho x >> \""+log+"\"\necho opencode/beam-free\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	c := &Core{Home: home, Live: true, Harness: harness.Env{Home: home, BinDir: bin}}
	calls := func() int {
		b, _ := os.ReadFile(log)
		return strings.Count(string(b), "x")
	}
	ctx := context.Background()
	c.account(nil, true)(ctx, "opencode")
	c.account(nil, true)(ctx, "opencode")
	if calls() != 1 {
		t.Fatalf("asked %d times, want 1 (cached)", calls())
	}
	c.account(map[string]bool{"opencode": true}, true)(ctx, "opencode")
	if calls() != 2 {
		t.Errorf("asked %d times after the switch, want 2", calls())
	}
}

// With discovery.auto off an answer is kept whatever its age, until a
// scan forgets it; with it on, an old answer is asked for again.
func TestAutoDiscoveryOffKeepsAnswersUntilAScan(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	home, bin := t.TempDir(), t.TempDir()
	log := filepath.Join(bin, "calls")
	if err := os.WriteFile(filepath.Join(bin, "opencode"), []byte("#!/bin/sh\necho x >> \""+log+"\"\necho opencode/beam-free\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_796_000_000, 0)
	c := &Core{Home: home, Live: true, Harness: harness.Env{Home: home, BinDir: bin}, Now: func() time.Time { return now }}
	calls := func() int {
		b, _ := os.ReadFile(log)
		return strings.Count(string(b), "x")
	}
	ctx := context.Background()
	c.account(nil, false)(ctx, "opencode")
	now = now.Add(3 * time.Hour)
	if c.account(nil, false)(ctx, "opencode"); calls() != 1 {
		t.Fatalf("asked %d times with auto off, want 1", calls())
	}
	if c.account(nil, true)(ctx, "opencode"); calls() != 2 {
		t.Fatalf("asked %d times with auto on after 3h, want 2", calls())
	}
	if err := c.ForgetAccounts(); err != nil {
		t.Fatal(err)
	}
	if c.account(nil, false)(ctx, "opencode"); calls() != 3 {
		t.Errorf("asked %d times after a scan, want 3", calls())
	}
	// Another process sees the scan too.
	c2 := &Core{Home: home, Live: true, Harness: c.Harness, Now: c.Now}
	if c2.account(nil, false)(ctx, "opencode"); calls() != 3 {
		t.Errorf("a fresh answer was asked for again: %d", calls())
	}
}
