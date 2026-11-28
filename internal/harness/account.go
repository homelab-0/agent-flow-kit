package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Account is what one harness says about this account right now: the plan,
// the models it can run, and every kind of usage it reports. Each field is
// what the CLI itself printed. A field the CLI doesn't report stays empty,
// and UsageNote says why there is no usage figure; nothing is estimated.
type Account struct {
	Harness string `json:"harness"`
	// Plan is the plan or tier name, as the CLI words it ("pro",
	// "max_20x").
	Plan string `json:"plan,omitempty"`
	// Models are the models this account can run, in the CLI's order.
	// ModelsKnown is false when the CLI gave no list: that is "AFK
	// doesn't know", not "it has none".
	Models       []string `json:"models,omitempty"`
	ModelsKnown  bool     `json:"models_known,omitempty"`
	DefaultModel string   `json:"default_model,omitempty"`
	// Windows are the plan's usage windows (5-hour, weekly, ...).
	Windows []Window `json:"windows,omitempty"`
	// Extra is usage beyond the plan's windows: credits, overage.
	Extra *Extra `json:"extra,omitempty"`
	// UsageNote says, in a few words for the person, why Windows is
	// empty.
	UsageNote string `json:"usage_note,omitempty"`
	// At is when the CLI was asked (unix seconds).
	At int64 `json:"at"`
}

// Window is one usage window of a plan.
type Window struct {
	// Minutes is the window's length (300 for 5 hours, 10080 for a week);
	// 0 when the CLI didn't say.
	Minutes int     `json:"minutes,omitempty"`
	UsedPct float64 `json:"used_pct"`
	// ResetsAt is when the window resets (unix seconds), 0 unknown.
	ResetsAt int64 `json:"resets_at,omitempty"`
}

// Extra is usage a plan allows beyond its windows.
type Extra struct {
	// Enabled: the account can keep going on credits or overage.
	Enabled bool `json:"enabled"`
	// Unlimited: no balance applies.
	Unlimited bool `json:"unlimited,omitempty"`
	// Balance is the credit balance as the CLI printed it ("" unknown).
	Balance string `json:"balance,omitempty"`
}

// Reporter is one harness's own way of saying what the account has. Each
// harness that reports anything has one, in its own file; how a CLI is
// asked changes with its releases, and stays in that file.
type Reporter interface {
	// Report asks the CLI at bin. It must spend no plan quota, read no
	// credential file and return within the context's deadline.
	Report(ctx context.Context, e Env, bin string) Account
}

// reporters are the harnesses with a Reporter of their own. A harness not
// listed here gets the generic one, which reads the model list its
// manifest names.
var reporters = map[string]Reporter{}

func registerReporter(name string, r Reporter) { reporters[name] = r }

// ReportLimit is how long one harness may take to report.
const ReportLimit = 8 * time.Second

// Ask asks an installed harness what this account has. ok is false when
// the harness isn't known or isn't installed.
func Ask(ctx context.Context, e Env, name string) (Account, bool) {
	a, ok := Lookup(name)
	if !ok {
		return Account{}, false
	}
	bin := Locate(e, a)
	if bin == "" {
		return Account{}, false
	}
	ctx, cancel := context.WithTimeout(ctx, ReportLimit)
	defer cancel()
	r, own := reporters[a.Name]
	if !own {
		r = manifestReporter{a.Manifest}
	}
	rep := r.Report(ctx, e, bin)
	rep.Harness = a.Name
	if rep.At == 0 {
		rep.At = time.Now().Unix()
	}
	if len(rep.Windows) == 0 && rep.UsageNote == "" {
		rep.UsageNote = a.Display + " doesn't report plan usage"
	}
	return rep, true
}

// manifestReporter is the generic Reporter: the model list command in the
// manifest, and nothing about usage.
type manifestReporter struct{ m Manifest }

func (r manifestReporter) Report(ctx context.Context, _ Env, bin string) Account {
	var rep Account
	rep.Models, rep.ModelsKnown = listModels(ctx, bin, r.m.ModelList)
	return rep
}

// listModels runs a manifest's model list command.
func listModels(ctx context.Context, bin string, ml ModelList) ([]string, bool) {
	if len(ml.Command) < 2 {
		return nil, false
	}
	out, ok := run(ctx, bin, ml.Command[1:]...)
	if !ok {
		return nil, false
	}
	models := ParseModelList(ml.Format, out)
	return models, len(models) > 0
}

// run runs a CLI command with stdin closed and returns its stdout. ok is
// false when it failed or ran out of time.
func run(ctx context.Context, bin string, args ...string) ([]byte, bool) {
	cmd := exec.CommandContext(ctx, bin, args...)
	var out bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, &out, nil
	// Node CLIs can leave children holding the pipe; don't wait on them.
	cmd.WaitDelay = time.Second
	if err := cmd.Run(); err != nil || ctx.Err() != nil {
		return nil, false
	}
	return out.Bytes(), true
}

// ParseModelList reads a model list in one of ModelListFormats. The names
// come back in the CLI's order, each once.
func ParseModelList(format string, out []byte) []string {
	var got []string
	switch format {
	case "codex-json":
		// {"models":[{"slug":"gpt-6.2-sol","visibility":"list"|"hide",...}]}
		var d struct {
			Models []struct {
				Slug       string `json:"slug"`
				Visibility string `json:"visibility"`
			} `json:"models"`
		}
		if json.Unmarshal(out, &d) != nil {
			return nil
		}
		for _, m := range d.Models {
			if m.Visibility == "" || m.Visibility == "list" {
				got = append(got, m.Slug)
			}
		}
	case "grok-text":
		// "Available models:" then "* grok-4.7 (default)" / "  grok-4.6".
		in := false
		for _, l := range strings.Split(string(out), "\n") {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(strings.ToLower(t), "available models") {
				in = true
				continue
			}
			if !in || t == "" {
				continue
			}
			t = strings.TrimSpace(strings.TrimLeft(t, "*-• "))
			if f := strings.Fields(t); len(f) > 0 {
				got = append(got, f[0])
			}
		}
	case "tsv":
		for _, l := range strings.Split(string(out), "\n") {
			id, _, _ := strings.Cut(l, "\t")
			got = append(got, strings.TrimSpace(id))
		}
	case "lines":
		for _, l := range strings.Split(string(out), "\n") {
			got = append(got, strings.TrimSpace(l))
		}
	}
	seen := map[string]bool{}
	var models []string
	for _, m := range got {
		if !modelNameRE.MatchString(m) || seen[m] {
			continue
		}
		seen[m] = true
		models = append(models, m)
	}
	return models
}

// modelNameRE is what a model name looks like; anything else on a line
// (a heading, a notice, an error) is not taken for one.
var modelNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/@-]{1,119}$`)
