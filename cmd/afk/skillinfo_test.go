package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSkillInfo(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte("---\nname: x\ndescription: \"Triage open PRs.\"\n---\n\n# x\ndescription: not this\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("n"), 0o644); err != nil {
		t.Fatal(err)
	}
	desc, files, mod := skillInfo(dir)
	if desc != "Triage open PRs." || files != 2 || mod.IsZero() {
		t.Errorf("skillInfo = %q, %d, %v", desc, files, mod)
	}
	if d, n, _ := skillInfo(filepath.Join(dir, "missing")); d != "" || n != 0 {
		t.Errorf("missing folder: %q, %d", d, n)
	}
}
