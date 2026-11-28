package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
)

// afkPackage is AFK's own npm package, and afkModule what go install
// builds it from.
const (
	afkPackage = "@homelab0/afk"
	afkModule  = "github.com/homelab-0/agent-flow-kit/cmd/afk"
)

const updateHelp = `Usage: afk update [--check] [-y] [--dry-run]

Updates afk itself, the way it was installed: npm, bun, pnpm or go
install. It shows the command first and asks once; -y skips the question.

  --check     say whether a newer afk is out, and change nothing
  --dry-run   show the command, and run nothing

To update an agent CLI, use: afk harness update <name>
`

// isUpdateCommand says whether argv is "afk update" and not a prompt that
// starts with the word (afk update the README).
func isUpdateCommand(argv []string) bool {
	if len(argv) == 0 || argv[0] != "update" {
		return false
	}
	for _, a := range argv[1:] {
		switch a {
		case "--check", "-y", "--yes", "--dry-run", "-h", "--help", "help":
		default:
			return false
		}
	}
	return true
}

// selfInstall works out how this afk was installed from where its
// executable lives: the method, and what to run for a version ("" when
// AFK can't update it itself, with why in note).
func selfInstall(exe, resolved, home string) (method string, command func(v string) []string, note string) {
	paths := []string{filepath.ToSlash(exe), filepath.ToSlash(resolved)}
	has := func(sub string) bool {
		for _, p := range paths {
			if strings.Contains(p, sub) {
				return true
			}
		}
		return false
	}
	gobin := filepath.ToSlash(filepath.Join(home, "go", "bin")) + "/"
	switch {
	case has("/_npx/"):
		return "npx", nil, "this afk was started with npx, which keeps its own copy. Run: npx " + afkPackage + "@latest"
	case has("/mise/"):
		return "mise", nil, "this afk was installed with mise. Run: mise upgrade npm:" + afkPackage
	case has("/.bun/"):
		return "bun", func(v string) []string { return []string{"bun", "add", "-g", afkPackage + "@" + v} }, ""
	case has("/pnpm/"):
		return "pnpm", func(v string) []string { return []string{"pnpm", "add", "-g", afkPackage + "@" + v} }, ""
	case has("/node_modules/"):
		return "npm", func(v string) []string { return []string{"npm", "install", "-g", afkPackage + "@" + v} }, ""
	case home != "" && has(gobin):
		return "go", func(v string) []string { return []string{"go", "install", afkModule + "@v" + v} }, ""
	}
	return "self-managed", nil, "this afk wasn't installed with npm, bun, pnpm or go install, so AFK can't replace it. Get the new one from https://github.com/homelab-0/agent-flow-kit/releases, or install it with: npm install -g " + afkPackage
}

// selfPaths is this executable as started and with links followed.
func selfPaths() (exe, resolved string) {
	exe, err := os.Executable()
	if err != nil {
		return "", ""
	}
	resolved, err = filepath.EvalSymlinks(exe)
	if err != nil {
		resolved = exe
	}
	return exe, resolved
}

// updateCmd is `afk update`.
func updateCmd(argv []string, stdout, stderr io.Writer) int {
	info, ok := debug.ReadBuildInfo()
	have, _, _ := buildVersion(info, ok)
	exe, resolved := selfPaths()
	home, _ := os.UserHomeDir()
	return selfUpdate(hostOps(), have, exe, resolved, home, argv, stdout, stderr)
}

func selfUpdate(o hops, have, exe, resolved, home string, argv []string, stdout, stderr io.Writer) int {
	var check, yes, dry bool
	for _, a := range argv {
		switch a {
		case "--check":
			check = true
		case "-y", "--yes":
			yes = true
		case "--dry-run":
			dry = true
		default:
			fmt.Fprint(stdout, updateHelp)
			return 0
		}
	}
	ctx := context.Background()
	in, err := npmVersion(ctx, o, afkPackage, "latest")
	if err != nil {
		fmt.Fprintln(stderr, "afk update: couldn't look up the newest afk:", err)
		return 1
	}
	latest, okL := versionOf(plainVersion, in.Version)
	cur, okC := versionOf(anyVersion, have)
	if okL && okC && !versionLess(cur, latest) {
		fmt.Fprintf(stdout, "afk %s is the newest.\n", strings.TrimPrefix(have, "v"))
		return 0
	}
	fmt.Fprintf(stdout, "afk %s is out; this is %s.\n", in.Version, strings.TrimPrefix(have, "v"))
	if check {
		return 0
	}
	method, command, note := selfInstall(exe, resolved, home)
	if command == nil {
		fmt.Fprintln(stderr, "afk update: "+note)
		return 1
	}
	cmd := command(in.Version)
	fmt.Fprintf(stdout, "It was installed with %s, so afk update will run:\n  %s\n", method, strings.Join(cmd, " "))
	if dry {
		fmt.Fprintln(stdout, "(dry run: nothing was run)")
		return 0
	}
	if !yes {
		if !o.isTTY {
			fmt.Fprintln(stderr, "afk update: nobody to ask here; run it again with -y to go ahead")
			return 2
		}
		if !o.confirm("Go ahead?") {
			fmt.Fprintln(stdout, "Nothing was changed.")
			return 1
		}
	}
	out, code, err := o.run(ctx, cmd)
	if err != nil || code != 0 {
		fmt.Fprintf(stderr, "afk update: %s failed (exit %d): %s\n", strings.Join(cmd, " "), code, strings.TrimSpace(firstLines(out, 6)))
		return 1
	}
	fmt.Fprintf(stdout, "Updated to afk %s. Start afk again to use it.\n", in.Version)
	return 0
}
