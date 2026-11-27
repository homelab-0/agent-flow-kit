package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// setupLogos gets the route logos ready for this terminal. A hint about
// tmux holding images back is shown once per machine, not on every start.
func setupLogos() tui.Logos {
	logos, hint := tui.SetupLogos(os.Stdout, os.Getenv, tmuxShow)
	if hint != "" {
		if dir, err := runrec.Dir(); err == nil {
			hintOnce(filepath.Join(filepath.Dir(dir), "hints", "tmux-logos"), hint)
		}
	}
	return logos
}

// tmuxShow expands a tmux format for the current pane, or "" when tmux
// can't be asked.
func tmuxShow(format string) string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "tmux", "display-message", "-p", format).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// hintOnce prints hint to stderr unless the marker file says it has been
// shown, then writes the marker.
func hintOnce(marker, hint string) {
	if _, err := os.Stat(marker); err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, "afk: "+hint)
	if os.MkdirAll(filepath.Dir(marker), 0o700) == nil {
		_ = os.WriteFile(marker, nil, 0o600)
	}
}
