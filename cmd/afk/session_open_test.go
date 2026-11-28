package main

import (
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
)

func TestCanOpen(t *testing.T) {
	var none *ranHere
	if !strings.Contains(none.canOpen(), "nothing to open") {
		t.Errorf("no run yet: %q", none.canOpen())
	}
	codex := engine.Route{Harness: "codex", LaunchClass: "codex-native"}
	if got := (&ranHere{route: codex, rec: runrec.Record{Session: "01a22155-7368"}}).canOpen(); got != "" {
		t.Errorf("a codex run with a session id opens, got %q", got)
	}
	if got := (&ranHere{route: codex}).canOpen(); !strings.Contains(got, "didn't report a session id") {
		t.Errorf("no session id: %q", got)
	}
	oc := engine.Route{Harness: "opencode", LaunchClass: "opencode-native"}
	if got := (&ranHere{route: oc, rec: runrec.Record{Session: "abc12345"}}).canOpen(); !strings.Contains(got, "doesn't know how") {
		t.Errorf("a CLI with no resume command: %q", got)
	}
	gw := engine.Route{Harness: "claude", LaunchClass: "claude-gateway"}
	if got := (&ranHere{route: gw, rec: runrec.Record{Session: "abc12345"}}).canOpen(); !strings.Contains(got, "gateway") {
		t.Errorf("a gateway run: %q", got)
	}
}
