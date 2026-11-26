package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/core"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

const poolsUsage = `afk pools — plan and gateway pools

  afk pools [--json]
      each pool's state, how much is left, and where a measured window is
      heading at the rate so far (resets with quota unused, or runs out
      before its reset)

  afk pools clear [<pool>...] [--dry-run] [--json]
      forget recorded failures, so routing uses those pools again now:
      the named pools, or with none named, every pool and model mark

A failed run sets its pool aside for a while (sign-in 24 h, quota 1 h,
anything else 15 min). Clear a mark when it was wrong, or once you have
signed in again. afk --explain shows each pool's state.
`

func poolsCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) > 0 && (argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help") {
		fmt.Fprint(stdout, poolsUsage)
		return 0
	}
	if len(argv) == 0 || argv[0] == "--json" || argv[0] == "list" {
		if len(argv) > 0 && argv[0] == "list" {
			argv = argv[1:]
		}
		return poolsList(core.New(), argv, stdout, stderr)
	}
	if argv[0] != "clear" {
		fmt.Fprintf(stderr, "afk pools: unknown command %q\n%s", argv[0], poolsUsage)
		return 2
	}
	f, err := parseConfigFlags(argv[1:])
	if err != nil {
		fmt.Fprintln(stderr, "afk pools:", err)
		return 2
	}
	home, _ := os.UserHomeDir()
	path := router.ProbeEnv{Home: home, Getenv: os.Getenv}.SignalsPath()
	removed, err := router.ClearSignals(path, f.args, f.dryRun)
	if err != nil {
		fmt.Fprintln(stderr, "afk pools:", err)
		return 1
	}
	if removed == nil {
		removed = []string{}
	}
	if f.json {
		return printJSON(stdout, stderr, map[string]any{"cleared": removed, "dry_run": f.dryRun, "signals": path})
	}
	verb := "Cleared"
	if f.dryRun {
		verb = "Would clear"
	}
	if len(removed) == 0 {
		fmt.Fprintln(stdout, "Nothing to clear: no failure is recorded for", describe(f.args))
		return 0
	}
	fmt.Fprintf(stdout, "%s %s.\n", verb, strings.Join(removed, ", "))
	return 0
}

func describe(pools []string) string {
	if len(pools) == 0 {
		return "any pool."
	}
	return strings.Join(pools, ", ") + "."
}

// poolsList prints every pool, with its pacing line when it has one.
func poolsList(c *core.Core, argv []string, stdout, stderr io.Writer) int {
	f, err := parseConfigFlags(argv)
	if err == nil && (len(f.args) > 0 || f.dryRun) {
		err = fmt.Errorf("afk pools takes only --json")
	}
	if err != nil {
		fmt.Fprintln(stderr, "afk pools:", err)
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	p, err := c.Probe(ctx)
	if err != nil {
		fmt.Fprintln(stderr, "afk pools:", err)
		return 1
	}
	if f.json {
		return printJSON(stdout, stderr, map[string]any{"pools": p.Pools})
	}
	pacing := true
	if s, err := c.LoadSettings(c.Cwd); err == nil {
		pacing = s.Pacing
	}
	fmt.Fprint(stdout, poolsText(p, c.Now(), time.Local, pacing))
	return 0
}

// poolsText is the pools report for people.
// pacing says whether route.pacing is on, so the routing effect is shown
// only when it applies.
func poolsText(p *router.Probe, now time.Time, loc *time.Location, pacing bool) string {
	ids := make([]string, 0, len(p.Pools))
	for id := range p.Pools {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var b strings.Builder
	for _, id := range ids {
		pl := p.Pools[id]
		left := "?"
		if pl.HeadroomPct != nil {
			left = fmt.Sprintf("%.0f%% left", *pl.HeadroomPct)
		}
		basis := ""
		switch {
		case pl.QuotaSource == "codex_rate_limits":
			basis = ", measured"
		case pl.QuotaSource == "claude_rate_limit_event":
			basis = ", measured at the last afk -p run"
		case pl.QuotaSource == "local_5h_activity":
			basis = ", estimated"
		case strings.HasPrefix(pl.QuotaSource, "runtime_signal:"):
			basis = ", set by a failed run"
		}
		fmt.Fprintf(&b, "%-17s %-13s %s%s\n", id, pl.State, left, basis)
		if t := router.PaceText(pl.Pacing, now, loc); t != "" {
			adj := ""
			if pacing && pl.Pacing.Adjustment != 0 {
				adj = fmt.Sprintf(" (routing %+.1f)", pl.Pacing.Adjustment)
			}
			fmt.Fprintf(&b, "%-17s %s%s\n", "", t, adj)
		}
	}
	return b.String()
}
