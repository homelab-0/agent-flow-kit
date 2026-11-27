package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/skills"
)

func testSkills(t *testing.T) (skillsDeps, string) {
	t.Helper()
	home := t.TempDir()
	env := skillsEnvFor(home, func(string) string { return "" })
	return skillsDeps{
		env: env,
		targets: []skills.Target{
			{Harness: "claude", Dir: filepath.Join(home, ".claude", "skills")},
			{Harness: "codex", Dir: filepath.Join(home, ".codex", "skills")},
		},
		unsupported: []string{"grok"},
	}, home
}

func skillsRun(t *testing.T, d skillsDeps, args ...string) (string, int) {
	t.Helper()
	var out, errb bytes.Buffer
	code := runSkills(d, args, &out, &errb)
	return out.String() + errb.String(), code
}

func TestSkillsCommandFlow(t *testing.T) {
	d, home := testSkills(t)
	if out, code := skillsRun(t, d); code != 0 || !strings.Contains(out, "No skills yet") {
		t.Fatalf("empty status: %d %s", code, out)
	}
	out, code := skillsRun(t, d, "new", "pr-triage", "Use", "on", "PRs")
	if code != 0 || !strings.HasSuffix(strings.TrimSpace(out), filepath.Join("skills", "pr-triage", "SKILL.md")) {
		t.Fatalf("new: %d %s", code, out)
	}
	out, _ = skillsRun(t, d, "sync", "--dry-run")
	if !strings.Contains(out, "would add") || strings.Contains(out, "codex") == false {
		t.Fatalf("dry run: %s", out)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude", "skills", "pr-triage")); err == nil {
		t.Fatal("a dry run wrote a skill")
	}
	if out, code := skillsRun(t, d, "sync"); code != 0 || strings.Count(out, "add") != 2 {
		t.Fatalf("sync: %d %s", code, out)
	}
	// An edit inside codex is drift, never overwritten by a sync.
	p := filepath.Join(home, ".codex", "skills", "pr-triage", "SKILL.md")
	if err := os.WriteFile(p, []byte("mine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, _ = skillsRun(t, d)
	if !strings.Contains(out, "↻") || !strings.Contains(out, "pr-triage changed in codex") || !strings.Contains(out, "–") {
		t.Fatalf("drift status:\n%s", out)
	}
	skillsRun(t, d, "sync")
	if b, _ := os.ReadFile(p); string(b) != "mine\n" {
		t.Fatal("sync overwrote an edit")
	}
	if out, _ := skillsRun(t, d, "diff", "pr-triage", "codex"); !strings.Contains(out, "+ mine") {
		t.Fatalf("diff: %s", out)
	}
	if out, code := skillsRun(t, d, "restore", "pr-triage", "codex"); code != 0 || !strings.Contains(out, "Backup:") {
		t.Fatalf("restore: %d %s", code, out)
	}
	if b, _ := os.ReadFile(p); string(b) == "mine\n" {
		t.Fatal("restore left the edit")
	}
	// Off for one CLI: the next sync removes AFK's copy there.
	if _, code := skillsRun(t, d, "disable", "pr-triage", "codex"); code != 0 {
		t.Fatal("disable failed")
	}
	if out, _ := skillsRun(t, d, "sync"); !strings.Contains(out, "remove") {
		t.Fatalf("sync after disable: %s", out)
	}
	if _, code := skillsRun(t, d, "disable", "pr-triage", "nope"); code == 0 {
		t.Error("an unknown CLI should fail")
	}
	out, _ = skillsRun(t, d, "--json")
	var js struct {
		Schema      string
		Unsupported []string
		Skills      []skills.SkillStatus
	}
	if err := json.Unmarshal([]byte(out), &js); err != nil || js.Schema != "afk-skills/1" || js.Skills[0].Cells["codex"] != skills.Off || js.Unsupported[0] != "grok" {
		t.Fatalf("json: %v %s", err, out)
	}
}

func TestSkillsCommandUsage(t *testing.T) {
	d, _ := testSkills(t)
	for _, args := range [][]string{{"diff", "x"}, {"bogus"}, {"sync", "--nope"}, {"new"}} {
		if _, code := skillsRun(t, d, args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	if out, _ := skillsRun(t, d, "new", "../x"); !strings.Contains(out, "not a skill name") {
		t.Errorf("a bad name: %s", out)
	}
}

func TestSkillTargetsFollowManifests(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"claude", "grok"} {
		if err := os.WriteFile(filepath.Join(bin, n), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := map[string]string{"CLAUDE_CONFIG_DIR": filepath.Join(home, "cc")}
	he := harness.Env{Home: home, OS: "linux", BinDir: bin, Getenv: func(k string) string { return env[k] }}
	ts, un := skillTargets(he)
	if len(ts) != 1 || ts[0].Harness != "claude" || ts[0].Dir != filepath.Join(home, "cc", "skills") {
		t.Errorf("targets %+v", ts)
	}
	if len(un) != 1 || un[0] != "grok" {
		t.Errorf("unsupported %v", un)
	}
}
