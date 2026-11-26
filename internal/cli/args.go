// Package cli reads afk's command line.
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
	// The non-interactive modes.
	Print      bool   // -p, --print
	Explain    bool   // --explain, --dry-run
	JSON       bool   // --json
	LaunchPlan bool   // --launch-plan
	Route      string // --route (JSON, or - for stdin)
	Mode       string // --mode for --launch-plan
	// BadMode is a --mode value that is neither a permission mode nor a
	// launch-plan mode.
	BadMode string
	// Unknown is the first option this command line does not know.
	Unknown string

	unknown bool // an unknown option came before any -h
}

// Options that take a value.
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
		case "--route":
			a.Route = v
		case "--mode":
			// --mode is a permission mode (read-only, ask, edits, auto,
			// yolo) or, with --launch-plan, interactive or print.
			// The last permission flag wins, so a later --mode ask
			// turns an earlier --yolo off.
			switch v {
			case "read-only", "ask", "edits", "auto", "yolo":
				a.Flags.Perm = v
				a.Yolo = v == "yolo"
			case "interactive", "print":
				a.Mode = v
			default:
				a.BadMode = v
			}
		}
	}
	for i := 0; i < len(argv); i++ {
		x := argv[i]
		switch {
		case x == "--":
			words = append(words, argv[i+1:]...)
			i = len(argv)
			continue
		case x == "-y" || x == "--yes":
			a.Yes = true
			continue
		case x == "-h" || x == "--help":
			// Options are read in order: an unknown one before -h is
			// reported (exit 2) instead of the help.
			if !a.unknown {
				a.Help = true
			}
		case x == "-p" || x == "--print" || x == "--explain" || x == "--dry-run" || x == "--launch-plan" || x == "--json":
			switch x {
			case "-p", "--print":
				a.Print = true
			case "--explain", "--dry-run":
				a.Explain = true
			case "--json":
				a.JSON = true
			case "--launch-plan":
				a.LaunchPlan = true
			}
		case x == "--yolo":
			a.Yolo = true
			a.Flags.Perm = "yolo"
		case valued[x]:
			v := ""
			if i+1 < len(argv) {
				v = argv[i+1]
			}
			set(x, v)
			i++
			continue
		case strings.HasPrefix(x, "--") && strings.Contains(x, "=") && valued[x[:strings.Index(x, "=")]]:
			k := x[:strings.Index(x, "=")]
			set(k, x[strings.Index(x, "=")+1:])
		case strings.HasPrefix(x, "-"):
			if !a.Help {
				a.unknown = true
				if a.Unknown == "" {
					a.Unknown = x
				}
			}
		default:
			words = append(words, x)
		}
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
