package core

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

// When every route is set aside, afk says why instead of launching the
// router's fallback (claude/sonnet with a made-up score and headroom).
func TestNoRouteSaysWhyInsteadOfFallingBack(t *testing.T) {
	c, _, signals := printCore(t, func([]string) ([]byte, []byte, int) {
		t.Fatal("nothing may run")
		return nil, nil, 1
	})
	now := time.Unix(1764158400, 0)
	if err := router.MarkPoolDegraded(signals, "anthropic-max", "429 Too Many Requests", now); err != nil {
		t.Fatal(err)
	}
	_, err := c.Explain(context.Background(), engine.RouteFlags{Harness: "claude"}, "fix the failing test")
	var nr *NoRouteError
	if !errors.As(err, &nr) {
		t.Fatalf("want a NoRouteError, got %v", err)
	}
	if strings.Contains(nr.Msg, "litellm-local") {
		t.Errorf("no gateway is set up, yet the message names its pool: %q", nr.Msg)
	}
	for _, want := range []string{"anthropic-max is exhausted", "afk pools clear anthropic-max", "--harness and --model"} {
		if !strings.Contains(nr.Msg, want) {
			t.Errorf("message %q lacks %q", nr.Msg, want)
		}
	}
	res, err := c.Print(context.Background(), PrintRequest{Prompt: "fix the failing test", Flags: engine.RouteFlags{Harness: "claude"}}, nil)
	if err == nil && res.OK {
		t.Fatalf("print ran something: %+v", res)
	}
}
