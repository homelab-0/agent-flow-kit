package harness

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
)

// Claude Code (checked against 2.1.332).
//
// `claude auth status` prints the plan as JSON.
//
// The models come over print mode's control channel: with
// --input-format stream-json Claude Code answers a list_models control
// request and exits when its input ends. No message is sent, so no turn
// runs and nothing is spent (the output carries no turn count, cost or
// rate limit). It does run the person's SessionStart hooks, as any start
// of Claude Code does.
//
// Claude Code has no command that prints plan usage: that comes only
// with a request, in the rate_limit_event of a `claude -p --output-format
// stream-json` run, which AFK records when it runs one.
type claudeReporter struct{}

func init() { registerReporter("claude", claudeReporter{}) }

// claudeListModels is the one line written to Claude Code's stdin.
const claudeListModels = `{"type":"control_request","request":{"subtype":"list_models"}}` + "\n"

func (claudeReporter) Report(ctx context.Context, _ Env, bin string) Account {
	rep := Account{UsageNote: "Claude Code reports usage only with a run"}
	if out, ok := run(ctx, bin, "auth", "status"); ok {
		rep.Plan = ParseClaudePlan(out)
	}
	if out, ok := runIn(ctx, bin, []byte(claudeListModels),
		"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"); ok {
		rep.Models, rep.DefaultModel = ParseClaudeModels(out)
		rep.ModelsKnown = len(rep.Models) > 0
	}
	return rep
}

// ParseClaudePlan reads the plan from `claude auth status`. Only the plan
// fields are decoded; the account's email and organisation in the same
// document are never kept.
func ParseClaudePlan(out []byte) string {
	var d struct {
		PlanTier         string `json:"planTier"`
		SubscriptionType string `json:"subscriptionType"`
	}
	if json.Unmarshal(out, &d) != nil {
		return ""
	}
	if d.PlanTier != "" {
		return d.PlanTier
	}
	return d.SubscriptionType
}

// ParseClaudeModels reads the answer to a list_models control request
// from Claude Code's stream-json output:
//
//	{"type":"control_response","response":{"subtype":"success","response":
//	  {"models":[{"value":"default","resolvedModel":"claude-opus-5-5",...},
//	             {"value":"opus","resolvedModel":"claude-opus-5-5",...}]}}}
//
// The models are the names --model takes, in Claude Code's order. The
// "default" entry is not a model of its own: what it resolves to is
// returned as the default.
func ParseClaudeModels(out []byte) (models []string, def string) {
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64<<10), 4<<20)
	for sc.Scan() {
		var d struct {
			Type     string `json:"type"`
			Response struct {
				Subtype  string `json:"subtype"`
				Response struct {
					Models []struct {
						Value         string `json:"value"`
						ResolvedModel string `json:"resolvedModel"`
					} `json:"models"`
				} `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(sc.Bytes(), &d) != nil || d.Type != "control_response" || d.Response.Subtype != "success" {
			continue
		}
		seen := map[string]bool{}
		for _, m := range d.Response.Response.Models {
			switch {
			case m.Value == "default":
				def = m.ResolvedModel
			case modelNameRE.MatchString(m.Value) && !seen[m.Value]:
				seen[m.Value] = true
				models = append(models, m.Value)
			}
		}
		if len(models) > 0 {
			return models, def
		}
	}
	return nil, ""
}
