package harness

import (
	"reflect"
	"testing"
)

func TestResumeArgv(t *testing.T) {
	want := map[string][]string{
		"codex":  {"resume", "abc-123"},
		"claude": {"--resume", "abc-123"},
		"grok":   {"--resume", "abc-123"},
		"agy":    {"--resume", "abc-123"},
	}
	for name, w := range want {
		a, _ := Lookup(name)
		if got := a.Manifest.ResumeArgv("abc-123"); !reflect.DeepEqual(got, w) {
			t.Errorf("%s: got %q, want %q", name, got, w)
		}
		if a.Manifest.ResumeArgv("") != nil {
			t.Errorf("%s: no id, no command", name)
		}
	}
	if a, _ := Lookup("opencode"); a.Manifest.ResumeArgv("abc-123") != nil {
		t.Error("opencode names no resume command")
	}
}
