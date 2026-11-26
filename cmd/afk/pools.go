package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

const poolsUsage = `afk pools — plan and gateway pools

  afk pools clear [<pool>...] [--dry-run] [--json]
      forget recorded failures, so routing uses those pools again now:
      the named pools, or with none named, every pool and model mark

A failed run sets its pool aside for a while (sign-in 24 h, quota 1 h,
anything else 15 min). Clear a mark when it was wrong, or once you have
signed in again. afk --explain shows each pool's state.
`

func poolsCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) == 0 || argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help" {
		fmt.Fprint(stdout, poolsUsage)
		return 0
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
