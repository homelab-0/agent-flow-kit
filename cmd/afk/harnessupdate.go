package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

// updateAll is `afk harness update --all`: every installed CLI AFK knows
// how to update, shown together and agreed to once, the way `codex
// update` or `claude update` work for one.
func updateAll(ctx context.Context, o hops, f hflags, stdout, stderr io.Writer) int {
	var plans []*plan
	var skipped []string
	for _, a := range harness.All() {
		in := harness.Inspect(ctx, o.env, a, harness.Options{})
		if !in.Installed {
			continue
		}
		p, err := planUpdate(ctx, o, a, in)
		if err != nil {
			skipped = append(skipped, a.Name+": "+err.Error())
			continue
		}
		if p.Version != "" && sameVersion(p.Version, in.Version) {
			skipped = append(skipped, fmt.Sprintf("%s: already on %s, the newest release AFK would install", a.Name, p.Version))
			continue
		}
		plans = append(plans, p)
	}
	if f.json && (f.dryRun || len(plans) == 0) {
		return printHJSON(stdout, stderr, map[string]any{"plans": plans, "skipped": skipped, "dry_run": f.dryRun})
	}
	msgs := stdout
	if f.json {
		msgs = stderr
	}
	for _, s := range skipped {
		fmt.Fprintf(msgs, "  · %s\n", s)
	}
	if len(plans) == 0 {
		fmt.Fprintln(msgs, "Nothing to update.")
		return 0
	}
	fmt.Fprintf(msgs, "afk harness update will update %s:\n", plural(len(plans), "CLI"))
	for _, p := range plans {
		fmt.Fprintf(msgs, "  %-10s %s\n", p.Harness, strings.Join(p.Command, " "))
		for _, s := range p.Scripts {
			fmt.Fprintf(msgs, "  %-10s the package runs this on install: %s\n", "", s)
		}
		for _, n := range p.Notes {
			fmt.Fprintf(msgs, "  %-10s (%s)\n", "", n)
		}
	}
	if f.dryRun {
		fmt.Fprintln(stdout, "(dry run: nothing was run)")
		return 0
	}
	if !f.yes {
		if !o.isTTY {
			fmt.Fprintln(stderr, "afk harness: nobody to ask here; run it again with -y to go ahead")
			return 2
		}
		if !o.confirm("Go ahead?") {
			fmt.Fprintln(msgs, "Nothing was changed.")
			return 1
		}
	}
	// Each one on its own: one failing doesn't stop the rest.
	one := f
	one.yes, one.json = true, false
	failed := 0
	for _, p := range plans {
		fmt.Fprintf(msgs, "Updating %s…\n", p.Harness)
		if carryOut(ctx, o, p, one, msgs, stderr) != 0 {
			failed++
		}
	}
	if failed > 0 {
		fmt.Fprintf(stderr, "afk harness update: %d of %d failed\n", failed, len(plans))
		return 1
	}
	if f.json {
		return printHJSON(stdout, stderr, map[string]any{"plans": plans, "skipped": skipped, "dry_run": false, "done": true})
	}
	return 0
}

// sameVersion says whether two version strings name the same x.y.z.
func sameVersion(a, b string) bool {
	av, ok1 := versionOf(anyVersion, a)
	bv, ok2 := versionOf(anyVersion, b)
	return ok1 && ok2 && av == bv
}
