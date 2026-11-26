// Package router picks the agent CLI, model and effort for a task: the
// benchmark score for the kind of work, how much is left in each
// subscription pool, and cost, under fixed rules about which logins may be
// used where. It is the Go port of the bash engine's router
// (lib/afk-smart-router.sh and lib/afk-cli.sh), and gives the same picks.
package router

import (
	"fmt"
	"regexp"
	"strings"
)

// Tasks are the kinds of work a person can ask for.
var Tasks = []string{"coding", "quick", "complex", "review", "architecture", "webdev", "research", "security"}

// Prefers are the routing preferences.
var Prefers = []string{"balanced", "cheap", "best"}

// Word starts only, so "optimizing" and "vulnerability" match their stems.
const b = `(^|[^a-z])`

var (
	reAction   = regexp.MustCompile(b + `(fix|patch|add|implement|write|build|create|make|update|change|remove|delete|port|wire)([^a-z]|$)`)
	reSecurity = regexp.MustCompile(b + `(security|vulnerab|cve-|exploit|threat model|pentest|xss|csrf|sql injection|command injection|prompt injection|secret leak)`)
	reReview   = regexp.MustCompile(b + `(review|audit|look over|critique)`)
	reArch     = regexp.MustCompile(b + `(architect|design doc|system design|plan out|roadmap|prd([^a-z]|$)|spec out)`)
	reComplex  = regexp.MustCompile(b + `(refactor|migrat|rewrit|debug|race condition|deadlock|performance|optimi[sz]|concurren|memory leak)`)
	reWeb      = regexp.MustCompile(b + `(css|html|frontend|front-end|react|vue|svelte|tailwind|ui|ux|landing page|web page|component|responsive)([^a-z]|$)`)
	reResearch = regexp.MustCompile(b + `(research|compare|explain|what is|what are|why does|how does|summari[sz]|investigat)`)
	reQuick    = regexp.MustCompile(b + `(rename|typo|format|lint|bump|quick|small|one-liner|comment)([^a-z]|$)`)
)

// GuessTask reads the kind of work from a prompt. A prompt that asks for a
// change is never taken as research. An empty prompt is coding.
func GuessTask(prompt string) string {
	p := strings.ToLower(prompt)
	if p == "" {
		return "coding"
	}
	action := reAction.MatchString(p)
	switch {
	case reSecurity.MatchString(p):
		return "security"
	case reReview.MatchString(p):
		return "review"
	case reArch.MatchString(p):
		return "architecture"
	case reComplex.MatchString(p):
		return "complex"
	case reWeb.MatchString(p):
		return "webdev"
	case !action && reResearch.MatchString(p):
		return "research"
	case reQuick.MatchString(p):
		return "quick"
	}
	return "coding"
}

// TaskRoute maps a task and preference to the router's stage and risk.
// "best" asks for the strongest model the kind allows; "quick" never does.
func TaskRoute(task, prefer string) (stage, risk string, err error) {
	risk = "low"
	switch task {
	case "quick", "coding":
		stage = "build"
	case "complex":
		stage, risk = "build", "high"
	case "review":
		stage = "review-code"
	case "architecture":
		stage = "architecture"
	case "webdev":
		stage = "ux"
	case "research":
		stage = "research"
	case "security":
		stage = "review-security"
	default:
		return "", "", fmt.Errorf("unknown task %q (one of %s)", task, strings.Join(Tasks, ", "))
	}
	if prefer == "best" && task != "quick" {
		risk = "high"
	}
	return stage, risk, nil
}

// TaskClass is the benchmark class a stage is scored on.
func TaskClass(stage, risk string, surfaces []string, round, diffLines int) string {
	if stage == "review-security" || strings.HasPrefix(stage, "security") || strings.HasPrefix(stage, "threat") {
		return "security"
	}
	if stage == "spec" || stage == "build" {
		for _, s := range surfaces {
			switch strings.ToLower(strings.TrimSpace(s)) {
			case "security", "auth", "crypto", "iam", "cve", "vuln", "pentest":
				return "security"
			}
		}
	}
	planning := regexp.MustCompile(`^(spec|arch.*|build)$`)
	if risk == "critical" && planning.MatchString(stage) {
		return "frontier_synthesis"
	}
	if round >= 3 && risk == "high" && regexp.MustCompile(`^(spec|arch.*|build)$`).MatchString(stage) {
		return "frontier_synthesis"
	}
	switch {
	case strings.HasPrefix(stage, "arch"):
		return "architecture"
	case stage == "spec":
		if risk == "low" && diffLines < 80 {
			return "coding_standard"
		}
		return "architecture"
	}
	switch {
	case stage == "intake" || stage == "research":
		return "research"
	case stage == "ux":
		return "webdev"
	case stage == "build":
		if risk == "high" || risk == "critical" {
			return "coding_complex"
		}
		return "coding_standard"
	case strings.HasPrefix(stage, "review") || stage == "approve":
		return "coding_review"
	}
	return "coding_standard"
}
