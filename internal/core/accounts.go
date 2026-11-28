package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// How long a CLI's account report (plan, models, usage) is reused before
// the CLI is asked again. A report with nothing in it is retried sooner:
// the CLI may have been mid-update or slow to start.
const (
	accountTTL      = 5 * time.Minute
	accountEmptyTTL = 30 * time.Second
)

// accountEntry is one cached report and the binary it came from.
type accountEntry struct {
	Account harness.Account `json:"account"`
	Bin     string          `json:"bin"`
	Mtime   string          `json:"mtime"`
	// Vendor is whether the vendor usage lookup was on for this report.
	// Switching it makes the report stale.
	Vendor bool `json:"vendor,omitempty"`
}

// accountsPath is where account reports are kept between runs:
// AFK_ACCOUNTS_FILE, else ~/.config/afk/state/accounts.json. It holds
// plan names, model names and usage figures; never a login, also when
// the figures came from a vendor usage lookup.
func (c *Core) accountsPath() string {
	if p := c.getenv("AFK_ACCOUNTS_FILE"); p != "" {
		return p
	}
	return filepath.Join(c.Home, ".config", "afk", "state", "accounts.json")
}

// account is how the pool probe asks an installed CLI what this account
// has. Each CLI is asked through its own module in internal/harness; the
// answer is reused for a few minutes, in this process and across runs,
// and dropped when the CLI's binary changes. vendor names the CLIs whose
// saved login may be used to ask the vendor for usage
// (harness.<name>.vendor_usage); for every other CLI no login is read.
func (c *Core) account(vendor map[string]bool) func(ctx context.Context, h string) (harness.Account, bool) {
	if c.Accounts != nil {
		return c.Accounts
	}
	if !c.Live {
		return nil
	}
	return func(ctx context.Context, h string) (harness.Account, bool) {
		a, ok := harness.Lookup(h)
		if !ok {
			return harness.Account{}, false
		}
		bin := harness.Locate(c.Harness, a)
		if bin == "" {
			return harness.Account{}, false
		}
		mt := ""
		if fi, err := os.Stat(bin); err == nil {
			mt = strconv.FormatInt(fi.ModTime().UnixNano(), 10)
		}
		now := c.now().Unix()
		fresh := func(e accountEntry) bool {
			ttl := accountTTL
			if !e.Account.ModelsKnown && len(e.Account.Windows) == 0 && e.Account.Plan == "" {
				ttl = accountEmptyTTL
			}
			return e.Bin == bin && e.Mtime == mt && e.Vendor == vendor[h] && now-e.Account.At < int64(ttl/time.Second) && now >= e.Account.At
		}
		c.acctMu.Lock()
		if c.acctMemo == nil {
			c.acctMemo = map[string]accountEntry{}
			if b, err := os.ReadFile(c.accountsPath()); err == nil {
				_ = json.Unmarshal(b, &c.acctMemo)
			}
			if c.acctMemo == nil {
				// A file holding null decodes to a nil map.
				c.acctMemo = map[string]accountEntry{}
			}
		}
		hit, found := c.acctMemo[h]
		c.acctMu.Unlock()
		if found && fresh(hit) {
			return hit.Account, true
		}
		// A CLI that once answered its usage command as a prompt is never
		// given that command again on the same install.
		off := found && hit.Bin == bin && hit.Mtime == mt && hit.Account.UsageCommandSpent
		acct, ok := harness.AskWith(ctx, c.Harness, h, harness.AskOptions{VendorUsage: vendor[h], NoUsageCommand: off})
		if !ok || ctx.Err() != nil {
			return acct, ok
		}
		acct.At = now
		c.acctMu.Lock()
		c.acctMemo[h] = accountEntry{Account: acct, Bin: bin, Mtime: mt, Vendor: vendor[h]}
		if b, err := json.Marshal(c.acctMemo); err == nil {
			p := c.accountsPath()
			if os.MkdirAll(filepath.Dir(p), 0o700) == nil {
				_ = statefile.WriteJSON(p, b)
			}
		}
		c.acctMu.Unlock()
		return acct, true
	}
}
