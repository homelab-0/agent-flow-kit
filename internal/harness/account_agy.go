package harness

import (
	"context"
	"encoding/json"
	"regexp"
	"strconv"
	"time"
)

// Antigravity CLI (checked against 1.5.19).
//
// `agy models` lists the models the signed-in plan includes; the ones its
// picker marks "not included with your current plan" are left out by agy
// itself.
//
// Usage is agy's own /usage command, run in print mode:
//
//	agy -p /usage --output-format json --print-timeout 20s
//
// In print mode a slash command is handled by agy itself: no prompt goes
// to a model. The answer says so (num_turns 0, no conversation id, no
// tokens) and carries the plan's groups under command.data:
//
//	{"conversation_id":"","status":"SUCCESS","num_turns":0,
//	 "command":{"name":"usage","data":{"groups":[
//	   {"name":"Gemini Models","buckets":[
//	     {"window":"weekly","remaining_fraction":1,"reset_time":"2026-12-05T09:24:14Z"}]}]}}}
//
// Two guards keep that true. agy before 1.1.11 has no /usage in print
// mode and is not asked. And if an answer ever shows a turn ran, the
// report says so (UsageCommandSpent) and AFK never runs the command on
// that install again.
type agyReporter struct{}

func init() { registerReporter("agy", agyReporter{}) }

const agyNoUsage = "Antigravity doesn't report plan usage"

func (agyReporter) Report(ctx context.Context, _ Env, bin string) Account {
	a, _ := Lookup("agy")
	rep := Account{UsageNote: agyNoUsage}
	rep.Models, rep.ModelsKnown = listModels(ctx, bin, a.Manifest.ModelList)
	if usageCommandOff(ctx) {
		rep.UsageNote = "Antigravity answered /usage as a prompt once, so AFK stopped asking it"
		return rep
	}
	ver, ok := run(ctx, bin, "--version")
	if !ok || !versionAtLeast(string(ver), 1, 1, 11) {
		rep.UsageNote = "this Antigravity is too old to report plan usage (needs 1.1.11)"
		return rep
	}
	out, ok := runEnv(ctx, bin, nil, []string{"AGY_CLI_DISABLE_AUTO_UPDATE=true"},
		"-p", "/usage", "--output-format", "json", "--print-timeout", "20s")
	if !ok {
		return rep
	}
	windows, spent, ok := ParseAgyUsage(out)
	switch {
	case spent:
		rep.UsageCommandSpent = true
		rep.UsageNote = "Antigravity answered /usage as a prompt, so AFK stopped asking it"
	case ok && len(windows) > 0:
		rep.Windows, rep.UsageNote = windows, ""
	}
	return rep
}

// ParseAgyUsage reads the answer to `agy -p /usage --output-format json`.
// spent is true when the answer shows agy ran a turn for it: a turn
// count, a conversation or tokens. Its figures are then not read. ok is
// false when the answer isn't the usage command's.
func ParseAgyUsage(out []byte) (windows []Window, spent, ok bool) {
	var d struct {
		ConversationID string `json:"conversation_id"`
		Status         string `json:"status"`
		NumTurns       int    `json:"num_turns"`
		Usage          struct {
			TotalTokens int `json:"total_tokens"`
		} `json:"usage"`
		Command *struct {
			Name string `json:"name"`
			Data struct {
				Groups []struct {
					Name    string `json:"name"`
					Buckets []struct {
						Window            string   `json:"window"`
						RemainingFraction *float64 `json:"remaining_fraction"`
						ResetTime         string   `json:"reset_time"`
					} `json:"buckets"`
				} `json:"groups"`
			} `json:"data"`
		} `json:"command"`
	}
	if json.Unmarshal(out, &d) != nil {
		return nil, false, false
	}
	if d.NumTurns > 0 || d.ConversationID != "" || d.Usage.TotalTokens > 0 {
		return nil, true, false
	}
	if d.Command == nil || d.Command.Name != "usage" {
		return nil, false, false
	}
	for _, g := range d.Command.Data.Groups {
		for _, b := range g.Buckets {
			if b.RemainingFraction == nil {
				continue
			}
			w := Window{Scope: g.Name, UsedPct: 100 - 100*min(1, max(0, *b.RemainingFraction))}
			switch b.Window {
			case "5h":
				w.Minutes = 300
			case "weekly":
				w.Minutes = 10080
			}
			// agy writes 1970-01-01 for a window that hasn't started.
			if t, err := time.Parse(time.RFC3339, b.ResetTime); err == nil && t.Unix() > 0 {
				w.ResetsAt = t.Unix()
			}
			windows = append(windows, w)
		}
	}
	return windows, false, true
}

var versionRE = regexp.MustCompile(`(\d+)\.(\d+)\.(\d+)`)

// versionAtLeast reports whether the first x.y.z in s is at least the
// one given.
func versionAtLeast(s string, major, minor, patch int) bool {
	m := versionRE.FindStringSubmatch(s)
	if m == nil {
		return false
	}
	want := []int{major, minor, patch}
	for i, w := range want {
		got, _ := strconv.Atoi(m[i+1])
		if got != w {
			return got > w
		}
	}
	return true
}
