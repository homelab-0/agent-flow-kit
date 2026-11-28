package harness

import "context"

// Antigravity CLI (checked against 1.5.19).
//
// `agy models` lists the models the signed-in plan includes; the ones its
// picker marks "not included with your current plan" are left out by agy
// itself. Antigravity keeps its quota in memory only: no command prints
// it.
type agyReporter struct{}

func init() { registerReporter("agy", agyReporter{}) }

func (agyReporter) Report(ctx context.Context, _ Env, bin string) Account {
	a, _ := Lookup("agy")
	rep := Account{UsageNote: "Antigravity doesn't report plan usage"}
	rep.Models, rep.ModelsKnown = listModels(ctx, bin, a.Manifest.ModelList)
	return rep
}
