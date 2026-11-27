package main

import (
	"context"
	"os"
	"os/exec"
	"runtime/debug"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// headerInfo is what the header card shows: the version, the folder and
// the git branch. Esc is drawn unless NO_COLOR is set.
func headerInfo() *tui.Header {
	info, ok := debug.ReadBuildInfo()
	v, _, _ := buildVersion(info, ok)
	dir, _ := os.Getwd()
	home, _ := os.UserHomeDir()
	return &tui.Header{
		Version: v,
		Dir:     tui.HomeDir(dir, home),
		Branch:  gitBranch(dir),
		Art:     os.Getenv("NO_COLOR") == "",
	}
}

// gitBranch is the current branch, the short commit on a detached HEAD,
// or "" outside a repository. It never waits more than a second.
func gitBranch(dir string) string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		return ""
	}
	b := strings.TrimSpace(string(out))
	if b != "HEAD" {
		return b
	}
	out, err = exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
