// Package cli reads afk's command line the way the bash engine does, and
// decides whether the Go front end handles it or hands it to the engine.
package cli

import (
	"strings"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// Args is a parsed command line.
type Args struct {
	Flags  engine.RouteFlags
	Prompt string
	Pass   []string
	Yolo   bool
	Yes    bool
	Help   bool
	// Engine is set when the engine must handle the call itself: -p,
	// --explain/--dry-run, --launch-plan, --json, or an option this front end
	// does not know (the engine prints the same error it always has).
	Engine bool
	// Forward is the command line for the engine, without --yes.
	Forward []string

	unknown bool // an unknown option came before any -h
}

// Options that take a value, as in lib/afk-cli.sh.
var valued = map[string]bool{
	"--prompt": true, "--task": true, "--prefer": true, "--harness": true, "--model": true,
	"--effort": true, "--repo": true, "--pass": true, "--route": true, "--mode": true,
}

// Parse reads argv (without the program name).
func Parse(argv []string) Args {
	var a Args
	var words []string
	promptOpt := ""
	set := func(name, v string) {
		switch name {
		case "--prompt":
			promptOpt = v
		case "--task":
			a.Flags.Task = v
		case "--prefer":
			a.Flags.Prefer = v
		case "--harness":
			a.Flags.Harness = v
		case "--model":
			a.Flags.Model = v
		case "--effort":
			a.Flags.Effort = v
		case "--repo":
			a.Flags.Repo = v
		case "--pass":
			a.Pass = append(a.Pass, v)
		case "--route", "--mode":
			a.Engine = true
		}
	}
	for i := 0; i < len(argv); i++ {
		x := argv[i]
		switch {
		case x == "--":
			words = append(words, argv[i+1:]...)
			a.Forward = append(a.Forward, argv[i:]...)
			i = len(argv)
			continue
		case x == "-y" || x == "--yes":
			a.Yes = true
			continue
		case x == "-h" || x == "--help":
			// The engine reads options in order: an unknown one before -h
			// is reported (exit 2) instead of the help.
			if !a.unknown {
				a.Help = true
			}
		case x == "-p" || x == "--print" || x == "--explain" || x == "--dry-run" || x == "--launch-plan" || x == "--json":
			a.Engine = true
		case x == "--yolo":
			a.Yolo = true
		case valued[x]:
			v := ""
			if i+1 < len(argv) {
				v = argv[i+1]
			}
			set(x, v)
			a.Forward = append(a.Forward, x)
			if i+1 < len(argv) {
				a.Forward = append(a.Forward, argv[i+1])
			}
			i++
			continue
		case strings.HasPrefix(x, "--") && strings.Contains(x, "=") && valued[x[:strings.Index(x, "=")]]:
			k := x[:strings.Index(x, "=")]
			set(k, x[strings.Index(x, "=")+1:])
		case strings.HasPrefix(x, "-"):
			a.Engine = true
			if !a.Help {
				a.unknown = true
			}
		default:
			words = append(words, x)
		}
		a.Forward = append(a.Forward, x)
	}
	a.Prompt = strings.Join(words, " ")
	if promptOpt != "" {
		if a.Prompt != "" {
			a.Prompt += " "
		}
		a.Prompt += promptOpt
	}
	return a
}
