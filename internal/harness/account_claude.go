package harness

import (
	"context"
	"encoding/json"
)

// Claude Code (checked against 2.1.332).
//
// `claude auth status` prints the plan as JSON. Claude Code has no command
// that lists models or prints plan usage: usage comes only with a request,
// in the rate_limit_event of a `claude -p --output-format stream-json`
// run, which AFK records when it runs one.
type claudeReporter struct{}

func init() { registerReporter("claude", claudeReporter{}) }

func (claudeReporter) Report(ctx context.Context, _ Env, bin string) Account {
	rep := Account{UsageNote: "Claude Code reports usage only with a run"}
	if out, ok := run(ctx, bin, "auth", "status"); ok {
		rep.Plan = ParseClaudePlan(out)
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
