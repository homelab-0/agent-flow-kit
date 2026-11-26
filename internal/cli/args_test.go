package cli

import (
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	a := Parse([]string{"--task", "review", "--prefer=cheap", "--yes", "--yolo", "--pass", "--continue", "fix", "it", "--prompt", "now"})
	if a.Engine || !a.Yes || !a.Yolo || a.Flags.Task != "review" || a.Flags.Prefer != "cheap" || a.Prompt != "fix it now" {
		t.Fatalf("%+v", a)
	}
	if len(a.Pass) != 1 || a.Pass[0] != "--continue" {
		t.Errorf("pass %v", a.Pass)
	}
	if strings.Contains(strings.Join(a.Forward, " "), "--yes") {
		t.Error("--yes is not forwarded to the engine")
	}
	if got := strings.Join(a.Forward, " "); got != "--task review --prefer=cheap --yolo --pass --continue fix it --prompt now" {
		t.Errorf("forward %q", got)
	}
}

func TestParseDashPrompt(t *testing.T) {
	a := Parse([]string{"--harness", "claude", "--", "-n", "is", "a", "flag", "--yes"})
	if a.Engine || a.Prompt != "-n is a flag --yes" || a.Yes || a.Flags.Harness != "claude" {
		t.Fatalf("%+v", a)
	}
}

func TestParseEngineCases(t *testing.T) {
	for _, argv := range [][]string{{"-p", "x"}, {"--print", "x"}, {"--explain"}, {"--dry-run", "x"}, {"--json", "x"},
		{"--launch-plan", "--route", "{}"}, {"--bogus"}, {"-"}, {"--route", "{}"}} {
		if !Parse(argv).Engine {
			t.Errorf("%v goes to the engine", argv)
		}
	}
	if Parse([]string{"fix", "the", "test"}).Engine {
		t.Error("a plain prompt is interactive")
	}
	if !Parse([]string{"-h"}).Help {
		t.Error("-h is help")
	}
}

func TestUnknownOptionBeforeHelp(t *testing.T) {
	if a := Parse([]string{"--bogus", "-h"}); a.Help || !a.Engine {
		t.Errorf("--bogus -h goes to the engine, which reports the option: %+v", a)
	}
	if a := Parse([]string{"-h", "--bogus"}); !a.Help {
		t.Errorf("-h --bogus is help, as in bash: %+v", a)
	}
}
