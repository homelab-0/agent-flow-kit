package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

// scanRow is what one CLI answered in a scan.
type scanRow struct {
	Name      string `json:"name"`
	Installed bool   `json:"installed"`
	Version   string `json:"version,omitempty"`
	SignIn    string `json:"sign_in,omitempty"`
	Plan      string `json:"plan,omitempty"`
	// ModelsKnown says the CLI listed its models; Models is how many.
	ModelsKnown bool `json:"models_known"`
	Models      int  `json:"models"`
	// LimitWindows are the kinds of plan limit the CLI listed ("5h",
	// "weekly", "other"); absent when it listed none.
	LimitWindows []string `json:"limit_windows,omitempty"`
	UsageNote    string   `json:"usage_note,omitempty"`
}

// scan asks every installed CLI again, whatever was kept from the last
// time, and says what each answered.
func scan(ctx context.Context, c *core.Core, rep harness.Report) ([]scanRow, error) {
	if err := c.ForgetAccounts(); err != nil {
		return nil, err
	}
	r, _, err := c.Router(ctx, "")
	if err != nil {
		return nil, err
	}
	var rows []scanRow
	for _, h := range rep.Harnesses {
		row := scanRow{Name: h.Name, Installed: h.Installed, Version: h.Version}
		if h.Installed {
			row.SignIn = signInText(h)
			st := r.Probe.Harnesses[h.Name]
			row.Plan, row.ModelsKnown, row.Models, row.UsageNote = st.Plan, st.ModelsKnown, len(st.Models), st.UsageNote
			if p, ok := r.Probe.Pools[planPool[h.Name]]; ok {
				row.LimitWindows = p.LimitWindows
				if row.Plan == "" {
					row.Plan = p.Plan
				}
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// scanCmd is `afk harness scan`.
func scanCmd(argv []string, stdout, stderr io.Writer) int {
	asJSON := false
	for _, a := range argv {
		switch a {
		case "--json":
			asJSON = true
		default:
			fmt.Fprintf(stderr, "afk harness scan: unknown argument %q\n", a)
			return 2
		}
	}
	ctx := context.Background()
	rep := harness.Discover(ctx, harness.HostEnv(), harness.Options{})
	rows, err := scan(ctx, core.New(), rep)
	if err != nil {
		fmt.Fprintln(stderr, "afk harness scan:", err)
		return 1
	}
	if asJSON {
		return printJSON(stdout, stderr, map[string]any{"schema": "afk-harness-scan/1", "checked_at": rep.CheckedAt, "harnesses": rows})
	}
	fmt.Fprint(stdout, scanText(rows))
	return 0
}

// scanText is the scan as people read it: installed CLIs only.
func scanText(rows []scanRow) string {
	var b strings.Builder
	n := 0
	for _, r := range rows {
		if !r.Installed {
			continue
		}
		n++
		models := "models not listed by the CLI"
		if r.ModelsKnown {
			models = fmt.Sprintf("%d models", r.Models)
		}
		parts := []string{r.SignIn, models}
		if r.Plan != "" {
			parts = append(parts, "plan "+r.Plan)
		}
		if l := limitsText(r.LimitWindows); l != "" {
			parts = append(parts, l)
		} else if r.UsageNote != "" {
			parts = append(parts, r.UsageNote)
		}
		fmt.Fprintf(&b, "%-10s %-12s %s\n", r.Name, r.Version, strings.Join(parts, " · "))
	}
	if n == 0 {
		return "No agent CLI found on this machine.\n"
	}
	fmt.Fprintf(&b, "Asked %d installed CLIs again.\n", n)
	return b.String()
}

// limitsText names the limits a plan has and, when its CLI listed its
// windows, the usual one it doesn't have. "" when nothing was listed.
func limitsText(kinds []string) string {
	if len(kinds) == 0 {
		return ""
	}
	has := map[string]bool{}
	for _, k := range kinds {
		has[k] = true
	}
	var out []string
	switch {
	case has["5h"] && has["weekly"]:
		out = append(out, "5-hour and weekly limits")
	case has["weekly"]:
		out = append(out, "weekly limit", "no 5-hour limit")
	case has["5h"]:
		out = append(out, "5-hour limit", "no weekly limit")
	default:
		out = append(out, "no 5-hour or weekly limit")
	}
	if has["other"] {
		out = append(out, "a limit of another length")
	}
	return strings.Join(out, ", ")
}

// noLimit says whether the plan's CLI listed its limits and left this
// kind ("5h" or "weekly") out.
func noLimit(kinds []string, kind string) bool {
	if len(kinds) == 0 {
		return false
	}
	for _, k := range kinds {
		if k == kind {
			return false
		}
	}
	return true
}
