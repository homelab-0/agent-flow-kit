package main

import (
	"strings"
	"testing"
)

func TestLimitsText(t *testing.T) {
	for _, c := range []struct {
		kinds []string
		want  string
	}{
		{nil, ""},
		{[]string{"weekly", "5h"}, "5-hour and weekly limits"},
		{[]string{"weekly"}, "weekly limit, no 5-hour limit"},
		{[]string{"5h"}, "5-hour limit, no weekly limit"},
		{[]string{"other"}, "no 5-hour or weekly limit, a limit of another length"},
	} {
		if got := limitsText(c.kinds); got != c.want {
			t.Errorf("%v: %q, want %q", c.kinds, got, c.want)
		}
	}
	// Nothing listed is unknown, never "no limit".
	if noLimit(nil, "5h") || !noLimit([]string{"weekly"}, "5h") || noLimit([]string{"weekly"}, "weekly") {
		t.Error("noLimit")
	}
}

func TestScanText(t *testing.T) {
	out := scanText([]scanRow{
		{Name: "codex", Installed: true, Version: "0.172.0", SignIn: "signed in", Plan: "pro", ModelsKnown: true, Models: 11, LimitWindows: []string{"weekly"}},
		{Name: "pi", Installed: true, Version: "1.7.0", SignIn: "signed out", UsageNote: "Pi doesn't report plan usage"},
		{Name: "gemini"},
	})
	for _, want := range []string{"codex", "11 models", "plan pro", "weekly limit, no 5-hour limit", "models not listed by the CLI", "Pi doesn't report plan usage", "Asked 2 installed CLIs again."} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "gemini") {
		t.Error("a CLI that isn't installed is listed")
	}
	if got := scanText(nil); !strings.Contains(got, "No agent CLI") {
		t.Errorf("empty scan: %q", got)
	}
}
