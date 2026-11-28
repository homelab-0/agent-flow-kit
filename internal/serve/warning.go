package serve

import (
	"fmt"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
)

// HarnessKeyWarning is what AFK says when a key is made for one CLI: the
// key puts that CLI's sign-in behind an API, and the vendor's terms, not
// AFK, decide what the sign-in may be used for. AFK warns and sets
// careful limits; the choice stays with the key's owner.
func HarnessKeyWarning(display, vendor string, l apikey.Limits) []string {
	if display == "" {
		display = "this CLI"
	}
	whose := "Its vendor's terms decide"
	if vendor != "" {
		whose = vendor + "'s terms decide"
	}
	return []string{
		fmt.Sprintf("This key lets other programs use your %s sign-in through AFK.", display),
		whose + " what that sign-in may be used for. AFK doesn't check them and won't stop you.",
		"What most often gets an account limited or closed:",
		"  - several people sharing one subscription",
		"  - traffic no single person would produce: around the clock, or many runs at once",
		"  - reselling access, or putting the sign-in behind a public service",
		fmt.Sprintf("The key starts at %s, about what one person does by hand. Each limit is yours to change or turn off.", l),
	}
}

// PlanRunsWarning is what AFK says when serve.plan_runs is turned on.
func PlanRunsWarning() []string {
	return []string{
		"With this on, a call through an AFK key may run a CLI on its own sign-in: your subscriptions.",
		"Each vendor's terms decide what its sign-in may be used for. AFK doesn't check them and won't stop you.",
		"Off, calls are answered only by a gateway, a local engine or a free pool.",
	}
}
