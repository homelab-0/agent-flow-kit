package main

import (
	"fmt"
	"io"
	"strings"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
)

const trustUsage = `afk trust — the directories where yolo may run

  afk trust list [--json]                     the trusted directories
  afk trust add <dir> [--dry-run] [--json]    trust a git repository, or a
                                              folder of them (every git
                                              repository below it counts)
  afk trust remove <dir> [--dry-run] [--json]

yolo runs only inside a git repository that is, or is under, a trusted
directory. Your home directory, and anything above it, can't be trusted.
The list is trust.repos in config.toml.
`

func trustCmd(argv []string, stdout, stderr io.Writer) int {
	if len(argv) == 0 || argv[0] == "-h" || argv[0] == "--help" || argv[0] == "help" {
		fmt.Fprint(stdout, trustUsage)
		return 0
	}
	f, err := parseConfigFlags(argv[1:])
	if err != nil {
		fmt.Fprintln(stderr, "afk trust:", err)
		return 2
	}
	e := configEnv()
	paths := config.PathsFor(e.Home, e.Getenv)
	switch argv[0] {
	case "list":
		file, err := config.Load(paths.Config)
		if err != nil {
			fmt.Fprintln(stderr, "afk trust:", err)
			return 1
		}
		repos := file.Trust.Repos
		if repos == nil {
			repos = []string{}
		}
		if f.json {
			return printJSON(stdout, stderr, map[string]any{"trusted": repos, "config": paths.Config})
		}
		if len(repos) == 0 {
			fmt.Fprintln(stdout, "Nothing is trusted yet, so yolo runs nowhere. afk trust add <dir> trusts a git repository or a folder of them.")
			return 0
		}
		for _, r := range repos {
			fmt.Fprintln(stdout, r)
		}
		return 0
	case "add", "remove":
		if len(f.args) != 1 {
			fmt.Fprintf(stderr, "afk trust %s: needs one directory\n", argv[0])
			return 2
		}
		var ch *config.TrustChange
		if argv[0] == "add" {
			ch, err = config.TrustAdd(paths, e.Home, f.args[0], f.dryRun)
		} else {
			ch, err = config.TrustRemove(paths, e.Home, f.args[0], f.dryRun)
		}
		if err != nil {
			fmt.Fprintln(stderr, "afk trust:", err)
			return 1
		}
		if f.json {
			return printJSON(stdout, stderr, struct {
				*config.TrustChange
				DryRun bool `json:"dry_run"`
			}{ch, f.dryRun})
		}
		switch {
		case argv[0] == "add" && !ch.Changed:
			fmt.Fprintf(stdout, "%s is already trusted.\n", ch.Dir)
		case argv[0] == "add" && f.dryRun:
			fmt.Fprintf(stdout, "Would trust %s. yolo could then run in:\n", ch.Dir)
		case argv[0] == "add":
			fmt.Fprintf(stdout, "Trusted %s. yolo may now run in:\n", ch.Dir)
		case len(ch.StillTrustedBy) > 0:
			verb := "Removed"
			if f.dryRun {
				verb = "Would remove"
			}
			fmt.Fprintf(stdout, "%s %s from trust.repos, but yolo stays allowed there: %s is still trusted.\n", verb, ch.Dir, strings.Join(ch.StillTrustedBy, ", "))
		case f.dryRun:
			fmt.Fprintf(stdout, "Would stop trusting %s.\n", ch.Dir)
		default:
			fmt.Fprintf(stdout, "%s is no longer trusted.\n", ch.Dir)
		}
		if argv[0] == "add" {
			for _, r := range ch.Covers {
				fmt.Fprintln(stdout, "  "+r)
			}
			if len(ch.Covers) > 0 && !isRepo(ch.Dir, ch.Covers) {
				fmt.Fprintln(stdout, "  (and any git repository added below it later)")
			}
		}
		if f.dryRun {
			fmt.Fprint(stdout, ch.Diff)
			fmt.Fprintln(stdout, "(dry run: nothing written)")
		}
		return 0
	}
	fmt.Fprintf(stderr, "afk trust: unknown command %s (see afk trust --help)\n", argv[0])
	return 2
}

func isRepo(dir string, covers []string) bool { return len(covers) == 1 && covers[0] == dir }
