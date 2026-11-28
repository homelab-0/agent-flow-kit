package harness

import "context"

// Grok CLI (checked against 1.0.92).
//
// `grok models` lists the account's models. `grok usage --json` answers
// "can't show your plan's usage here yet" unless Grok's shared daemon is
// on, so there is no usage figure to read from the shell.
type grokReporter struct{}

func init() { registerReporter("grok", grokReporter{}) }

func (grokReporter) Report(ctx context.Context, _ Env, bin string) Account {
	a, _ := Lookup("grok")
	rep := Account{UsageNote: "Grok shows plan usage only inside grok, with /usage"}
	rep.Models, rep.ModelsKnown = listModels(ctx, bin, a.Manifest.ModelList)
	return rep
}
