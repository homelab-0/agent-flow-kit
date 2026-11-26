package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/bench"
	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

const benchUsage = `afk bench — the benchmark catalog the router scores models with

  afk bench sync [--json]   refresh it now from the public leaderboards

The sync reads the LMArena agent, webdev and text leaderboards and
models.dev, and writes ~/.config/afk/benchmarks.json. A score no board
measures keeps its fixed estimate. afk also refreshes the catalog in the
background once a day; AFK_SKIP_BENCHMARK_AUTOSYNC=1 turns that off.

Exit status: 0 synced, 3 no leaderboard was reachable (the previous
catalog is kept), 1 the catalog could not be written.
`

func benchCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) == 0 || argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help" {
		fmt.Fprint(stdout, benchUsage)
		return 0
	}
	if argv[0] != "sync" {
		fmt.Fprintf(stderr, "afk bench: unknown command %s (see afk bench --help)\n", argv[0])
		return 2
	}
	asJSON, auto := false, false
	for _, a := range argv[1:] {
		switch a {
		case "--json":
			asJSON = true
		case "--auto":
			auto = true
		case "-h", "--help":
			fmt.Fprint(stdout, benchUsage)
			return 0
		default:
			fmt.Fprintf(stderr, "afk bench sync: unknown option %s\n", a)
			return 2
		}
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		fmt.Fprintln(stderr, "afk bench sync: no home directory to keep the catalog in")
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if auto {
		// The daily refresh afk starts in the background: quiet, and only
		// when it is due.
		bench.AutoSync(ctx, bench.Env{Home: home, Getenv: os.Getenv}, func(ctx context.Context) int {
			_, rc := runSync(ctx, home)
			return rc
		})
		return 0
	}
	rec, rc := runSync(ctx, home)
	if asJSON {
		b, _ := json.Marshal(rec)
		fmt.Fprintln(stdout, string(b))
		return rc
	}
	fmt.Fprint(stdout, receiptText(rec))
	return rc
}

func runSync(ctx context.Context, home string) (bench.Receipt, int) {
	var feeds bench.Fetcher = bench.HTTPFetcher{}
	if d := os.Getenv("AFK_BENCHMARK_FEED_DIR"); d != "" {
		feeds = bench.DirFetcher{Dir: d}
	}
	// [bench.sources] in config.toml can turn a feed off.
	if s, err := config.Resolve(config.Env{Home: home, Getenv: os.Getenv}); err == nil {
		feeds = onlyEnabled{feeds, s}
	}
	carry := bench.DefaultCarry
	if v, err := strconv.ParseInt(os.Getenv("AFK_BENCHMARK_CARRY_SEC"), 10, 64); err == nil && v >= 0 {
		carry = time.Duration(v) * time.Second
	}
	return bench.Sync(ctx, bench.Options{
		Base: router.DefaultCatalogJSON(), Out: bench.CatalogPath(home), Now: time.Now(), Carry: carry, Feeds: feeds,
	})
}

// onlyEnabled skips the feeds config.toml turns off: lmarena covers the
// three LMArena boards, modelsdev the models.dev feed.
type onlyEnabled struct {
	next bench.Fetcher
	s    config.Settings
}

func (o onlyEnabled) Fetch(ctx context.Context, name string) ([]byte, error) {
	src := "lmarena"
	if name == bench.FeedModelsDev {
		src = "modelsdev"
	}
	if !o.s.BenchSourceOn(src) {
		return nil, fmt.Errorf("%s is turned off in config.toml (bench.sources.%s)", name, src)
	}
	return o.next.Fetch(ctx, name)
}

// receiptText is the sync receipt for people.
func receiptText(r bench.Receipt) string {
	var b strings.Builder
	switch r.Result {
	case "error":
		fmt.Fprintf(&b, "afk bench sync: %s\n", r.Reason)
		return b.String()
	case "feeds_unavailable":
		b.WriteString("No leaderboard was reachable; no score was measured this time.\n")
	default:
		fmt.Fprintf(&b, "Synced %d candidates, %d measured scores.\n", deref(r.CandidatesCount), deref(r.LiveScores))
	}
	fmt.Fprintf(&b, "  catalog:         %s\n", r.CatalogPath)
	if f := r.Feeds; f != nil {
		fmt.Fprintf(&b, "  LMArena agent:   %s\n", f.Agent)
		fmt.Fprintf(&b, "  LMArena webdev:  %s\n", f.Webdev)
		fmt.Fprintf(&b, "  LMArena text:    %s\n", f.Text)
		fmt.Fprintf(&b, "  models.dev:      %s\n", f.ModelsDev)
	}
	if r.Unmatched != nil && len(*r.Unmatched) > 0 {
		fmt.Fprintf(&b, "  not on the agent board: %s\n", strings.Join(*r.Unmatched, ", "))
	}
	return b.String()
}

func deref(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}
