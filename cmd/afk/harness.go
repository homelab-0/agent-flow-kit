package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/term"

	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
	"github.com/jlengelbrecht/agent-flow-kit/internal/tui"
)

const harnessHelp = `Usage: afk harness [list] [--all] [--json]

Shows the agent CLIs AFK found on this machine: version, how each was
installed, the command that updates it, and whether it looks signed in.
Nothing is changed; each CLI is only asked for its --version.

  --all    also list the CLIs AFK supports that are not installed
  --json   machine-readable output (schema ` + harness.Schema + `)

The sign-in column reads what each CLI keeps on disk. "unknown" means AFK
has no reliable way to tell for that CLI; it is never a guess.
`

// harnessCmd runs "afk harness ...". It needs no engine.
func harnessCmd(argv []string, stdout, stderr io.Writer) int {
	asJSON, all := false, false
	for _, a := range argv {
		switch a {
		case "list", "ls":
		case "--json":
			asJSON = true
		case "--all", "-a":
			all = true
		case "-h", "--help", "help":
			fmt.Fprint(stdout, harnessHelp)
			return 0
		default:
			fmt.Fprintf(stderr, "afk harness: unknown argument %q\n\n%s", a, harnessHelp)
			return 2
		}
	}
	r := harness.Discover(context.Background(), harness.HostEnv(), harness.Options{})
	if asJSON {
		if !all {
			r.Harnesses = r.Installed()
			if r.Harnesses == nil {
				r.Harnesses = []harness.Info{}
			}
		}
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		enc.SetEscapeHTML(false)
		if err := enc.Encode(r); err != nil {
			fmt.Fprintln(stderr, "afk harness:", err)
			return 1
		}
		return 0
	}
	color := os.Getenv("NO_COLOR") == "" && term.IsTerminal(os.Stdout.Fd())
	dark := true
	if color {
		dark = lipgloss.HasDarkBackground(os.Stdin, os.Stdout)
	}
	fmt.Fprint(stdout, renderHarnesses(r, all, color, dark))
	return 0
}

// renderHarnesses draws the table people read.
func renderHarnesses(r harness.Report, all, color, dark bool) string {
	th := tui.NewTheme(dark)
	style := func(s lipgloss.Style, text string) string {
		if !color {
			return text
		}
		return s.Render(text)
	}
	rows := r.Harnesses
	if !all {
		rows = r.Installed()
	}
	head := []string{"CLI", "VERSION", "SIGN-IN", "INSTALLED WITH", "EFFORT"}
	cells := make([][]string, 0, len(rows))
	for _, h := range rows {
		ver := h.Version
		if ver == "" {
			ver = "n/e"
		}
		method := h.InstallMethod
		if h.Package != "" && h.Package != h.Name {
			method += " (" + h.Package + ")"
		}
		effort := "-"
		if len(h.Efforts) > 0 {
			effort = h.Efforts[0] + ".." + h.Efforts[len(h.Efforts)-1]
		}
		if !h.Installed {
			ver, method, effort = "", "", ""
		}
		cells = append(cells, []string{h.Name, ver, string(h.Auth), method, effort})
	}
	widths := make([]int, len(head))
	for i, c := range head {
		widths[i] = ansi.StringWidth(c)
	}
	for _, row := range cells {
		for i, c := range row {
			if n := ansi.StringWidth(c); n > widths[i] {
				widths[i] = n
			}
		}
	}
	pad := func(s string, w int) string { return s + strings.Repeat(" ", w-ansi.StringWidth(s)) }

	var b strings.Builder
	installed := len(r.Installed())
	fmt.Fprintf(&b, "%s %s\n\n", style(th.Bold, "Agent CLIs"),
		style(th.Dim, fmt.Sprintf("· %d of %d supported CLIs installed", installed, len(r.Harnesses))))
	if len(rows) == 0 {
		b.WriteString("  None of the supported CLIs is installed. Run `afk harness --all` to see them.\n")
		return b.String()
	}
	var hl []string
	for i, c := range head {
		hl = append(hl, pad(c, widths[i]))
	}
	b.WriteString("  " + style(th.Dim, strings.TrimRight(strings.Join(hl, "  "), " ")) + "\n")
	var problems []string
	for i, row := range cells {
		h := rows[i]
		var out []string
		for j, c := range row {
			p := pad(c, widths[j])
			switch {
			case j == 0 && h.Installed && h.Healthy:
				p = style(th.Bold, p)
			case j == 0:
				p = style(th.Dim, p)
			case j == 1 && !h.Healthy && h.Installed:
				p = style(th.Bad, p)
			case j == 2:
				switch h.Auth {
				case harness.AuthOK:
					p = style(th.OK, p)
				case harness.AuthSignedOut:
					p = style(th.Warn, p)
				default:
					p = style(th.Dim, p)
				}
			case j >= 3:
				p = style(th.Dim, p)
			}
			out = append(out, p)
		}
		b.WriteString("  " + strings.TrimRight(strings.Join(out, "  "), " ") + "\n")
		if h.Installed && !h.Healthy {
			problems = append(problems, fmt.Sprintf("%s: %s", h.Name, h.Problem))
		}
		if h.Auth == harness.AuthSignedOut && h.Login != "" {
			problems = append(problems, fmt.Sprintf("%s: not signed in; sign in with: %s", h.Name, h.Login))
		}
	}
	if len(problems) > 0 {
		b.WriteString("\n")
		for _, p := range problems {
			b.WriteString("  " + style(th.Warn, "!") + " " + p + "\n")
		}
	}
	return b.String()
}
