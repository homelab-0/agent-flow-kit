package router

import "testing"

// The expected kinds are what the bash engine's afk_cli_guess_task answers.
func TestGuessTaskMatchesBash(t *testing.T) {
	cases := map[string]string{
		"review this diff":                       "review",
		"design the architecture for sync":       "architecture",
		"make the landing page responsive":       "webdev",
		"explain how the scheduler works":        "research",
		"refactor the parser":                    "complex",
		"fix a typo in the readme":               "quick",
		"add a retry to the client":              "coding",
		"check for XSS in the form":              "security",
		"":                                       "coding",
		"find the vulnerability":                 "security",
		"fix the concurrency bug":                "complex",
		"use dependency injection":               "coding",
		"explain why the build fails and fix it": "coding",
		"Fix the flaky test":                     "coding",
		"Write a PRD for search":                 "architecture",
		"audit the auth flow":                    "review",
		"bump the version":                       "quick",
		"what is a monad":                        "research",
		"build a React component":                "webdev",
		"optimizing the query":                   "complex",
		"port the UI to vue":                     "webdev",
		"summarise the logs":                     "research",
	}
	for p, want := range cases {
		if got := GuessTask(p); got != want {
			t.Errorf("GuessTask(%q) = %s, want %s", p, got, want)
		}
	}
}

func TestTaskRoute(t *testing.T) {
	cases := []struct{ task, prefer, stage, risk string }{
		{"coding", "balanced", "build", "low"},
		{"coding", "best", "build", "high"},
		{"quick", "best", "build", "low"},
		{"complex", "cheap", "build", "high"},
		{"review", "balanced", "review-code", "low"},
		{"architecture", "balanced", "architecture", "low"},
		{"webdev", "balanced", "ux", "low"},
		{"research", "balanced", "research", "low"},
		{"security", "best", "review-security", "high"},
	}
	for _, c := range cases {
		st, rk, err := TaskRoute(c.task, c.prefer)
		if err != nil || st != c.stage || rk != c.risk {
			t.Errorf("TaskRoute(%s, %s) = %s %s %v, want %s %s", c.task, c.prefer, st, rk, err, c.stage, c.risk)
		}
	}
	if _, _, err := TaskRoute("knitting", "balanced"); err == nil {
		t.Error("an unknown task is accepted")
	}
}

func TestClampEffort(t *testing.T) {
	sup := []string{"low", "medium", "high"}
	for target, want := range map[int]string{1: "low", 3: "high", 4: "high", 5: "high"} {
		if got := clampEffort(target, sup); got != want {
			t.Errorf("clampEffort(%d) = %s, want %s", target, got, want)
		}
	}
	// A tie goes to the higher level.
	if got := clampEffort(2, []string{"low", "high"}); got != "high" {
		t.Errorf("tie = %s", got)
	}
}
