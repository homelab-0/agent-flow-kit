package cli

import "testing"

func TestParse(t *testing.T) {
	a := Parse([]string{"--task", "review", "--prefer=cheap", "--yes", "--yolo", "--pass", "--continue", "fix", "it", "--prompt", "now"})
	if a.Print || a.Explain || !a.Yes || !a.Yolo || a.Flags.Task != "review" || a.Flags.Prefer != "cheap" || a.Prompt != "fix it now" {
		t.Fatalf("%+v", a)
	}
	if len(a.Pass) != 1 || a.Pass[0] != "--continue" {
		t.Errorf("pass %v", a.Pass)
	}
}

func TestParseDashPrompt(t *testing.T) {
	a := Parse([]string{"--harness", "claude", "--", "-n", "is", "a", "flag", "--yes"})
	if a.Unknown != "" || a.Prompt != "-n is a flag --yes" || a.Yes || a.Flags.Harness != "claude" {
		t.Fatalf("%+v", a)
	}
}

func TestParseModes(t *testing.T) {
	cases := map[string]func(Args) bool{
		"-p":            func(a Args) bool { return a.Print },
		"--print":       func(a Args) bool { return a.Print },
		"--explain":     func(a Args) bool { return a.Explain },
		"--dry-run":     func(a Args) bool { return a.Explain },
		"--json":        func(a Args) bool { return a.JSON },
		"--launch-plan": func(a Args) bool { return a.LaunchPlan },
		"--bogus":       func(a Args) bool { return a.Unknown == "--bogus" },
		"-":             func(a Args) bool { return a.Unknown == "-" },
	}
	for flag, ok := range cases {
		if !ok(Parse([]string{flag, "x"})) {
			t.Errorf("%s not read", flag)
		}
	}
	if a := Parse([]string{"--route", "{}", "--mode", "print"}); a.Route != "{}" || a.Mode != "print" {
		t.Errorf("--route/--mode: %+v", a)
	}
	if a := Parse([]string{"fix", "the", "test"}); a.Print || a.Explain || a.Unknown != "" {
		t.Error("a plain prompt is interactive")
	}
	if !Parse([]string{"-h"}).Help {
		t.Error("-h is help")
	}
}

func TestUnknownOptionBeforeHelp(t *testing.T) {
	if a := Parse([]string{"--bogus", "-h"}); a.Help || a.Unknown != "--bogus" {
		t.Errorf("--bogus -h reports the option: %+v", a)
	}
	if a := Parse([]string{"-h", "--bogus"}); !a.Help {
		t.Errorf("-h --bogus is help: %+v", a)
	}
}
