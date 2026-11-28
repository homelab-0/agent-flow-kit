package harness

import (
	"context"
	"encoding/json"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// xAI's billing service, as Grok's own /usage screen asks it (checked
// against Grok CLI 1.0.92's login file).
//
// GET https://cli-chat-proxy.grok.com/v1/billing?format=credits with the
// token Grok saved answers, under "config" or at the top level,
//
//	{"creditUsagePercent":37,
//	 "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"...","end":"..."},
//	 "billingPeriodStart":"...","billingPeriodEnd":"...",
//	 "subscriptionTier":"SuperGrok",
//	 "monthlyLimit":{"val":"100"},"used":{"val":"12.5"},
//	 "onDemandCap":{"val":"50"},"onDemandUsed":{"val":"0"},
//	 "prepaidBalance":{"val":"0"}}
//
// The login is ~/.grok/auth.json (GROK_HOME moves it): one entry per
// sign-in, keyed by who issued it.

var grokBillingURL = "https://cli-chat-proxy.grok.com/v1/billing"

func (grokReporter) Vendor() string { return "xAI" }

func (grokReporter) VendorUsage(ctx context.Context, e Env, rep *Account) {
	dir := e.getenv("GROK_HOME")
	if dir == "" {
		dir = filepath.Join(e.Home, ".grok")
	}
	raw, ok := readLogin(filepath.Join(dir, "auth.json"))
	if !ok {
		rep.UsageNote = "Grok isn't signed in, so xAI can't be asked"
		return
	}
	token, user, expires := grokLogin(raw)
	if token == "" {
		rep.UsageNote = "Grok isn't signed in, so xAI can't be asked"
		return
	}
	if expires != 0 && expires <= time.Now().Unix() {
		// Renewing a login is Grok's job; AFK never does it.
		rep.UsageNote = "Grok's saved login has expired; open grok once to renew it"
		return
	}
	header := map[string]string{
		"Authorization":    "Bearer " + token,
		"X-XAI-Token-Auth": "xai-grok-cli",
		"Accept":           "application/json",
	}
	if user != "" {
		header["x-userid"] = user
	}
	body, err := vendorGet(ctx, grokBillingURL+"?format=credits", header)
	if err != nil {
		rep.UsageNote = vendorNote("xAI", "grok", err)
		return
	}
	plan, windows, extra := ParseGrokBilling(body)
	if len(windows) == 0 {
		// The plain form carries the monthly figures when the credits
		// form has no window.
		if body, err := vendorGet(ctx, grokBillingURL, header); err == nil {
			p, w, x := ParseGrokBilling(body)
			if plan == "" {
				plan = p
			}
			if extra == nil {
				extra = x
			}
			windows = w
		}
	}
	if plan != "" && rep.Plan == "" {
		rep.Plan = plan
	}
	if extra != nil {
		rep.Extra = extra
	}
	if len(windows) == 0 {
		rep.UsageNote = "xAI's billing service gave no usage figure"
		return
	}
	rep.Windows, rep.UsageNote, rep.UsageSource = windows, "", SourceVendor
}

// grokLogin picks the sign-in to use from Grok's login file: the one
// xAI's own sign-in service issued, else the first that has a token.
// Only the token, the user id and the expiry are read.
func grokLogin(raw []byte) (token, user string, expires int64) {
	var entries map[string]json.RawMessage
	if json.Unmarshal(raw, &entries) != nil {
		return "", "", 0
	}
	const issuer = "https://auth.x.ai"
	keys := make([]string, 0, len(entries))
	for k := range entries {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		pi := keys[i] == issuer || strings.HasPrefix(keys[i], issuer+"::")
		pj := keys[j] == issuer || strings.HasPrefix(keys[j], issuer+"::")
		if pi != pj {
			return pi
		}
		return keys[i] < keys[j]
	})
	for _, k := range keys {
		var en struct {
			Key       string          `json:"key"`
			UserID    string          `json:"user_id"`
			ExpiresAt json.RawMessage `json:"expires_at"`
		}
		if json.Unmarshal(entries[k], &en) == nil && en.Key != "" {
			return en.Key, en.UserID, flexTime(en.ExpiresAt)
		}
	}
	return "", "", 0
}

// grokVal is an amount xAI writes as {"val":"12.5"} or {"val":12.5}.
type grokVal struct {
	Val json.RawMessage `json:"val"`
}

func (v *grokVal) num() (float64, bool) {
	if v == nil {
		return 0, false
	}
	s := strings.Trim(strings.TrimSpace(string(v.Val)), `"`)
	f, err := strconv.ParseFloat(s, 64)
	return f, err == nil && s != ""
}

// ParseGrokBilling reads xAI's billing answer: the plan, the weekly
// credit window and the monthly spend window when it has them, and the
// usage beyond the plan (on-demand cap, prepaid balance).
//
// A missing creditUsagePercent is read as 0% used only when the answer
// names a weekly period that matches the billing period and nothing in
// it says the figure was left out; otherwise it is unknown.
func ParseGrokBilling(body []byte) (plan string, windows []Window, extra *Extra) {
	type period struct {
		Type  string          `json:"type"`
		Start json.RawMessage `json:"start"`
		End   json.RawMessage `json:"end"`
	}
	type config struct {
		CreditUsagePercent json.RawMessage `json:"creditUsagePercent"`
		CurrentPeriod      *period         `json:"currentPeriod"`
		BillingPeriodStart json.RawMessage `json:"billingPeriodStart"`
		BillingPeriodEnd   json.RawMessage `json:"billingPeriodEnd"`
		SubscriptionTier   string          `json:"subscriptionTier"`
		MonthlyLimit       *grokVal        `json:"monthlyLimit"`
		Used               *grokVal        `json:"used"`
		OnDemandCap        *grokVal        `json:"onDemandCap"`
		OnDemandUsed       *grokVal        `json:"onDemandUsed"`
		PrepaidBalance     *grokVal        `json:"prepaidBalance"`
	}
	var d struct {
		config
		Config *config `json:"config"`
	}
	if json.Unmarshal(body, &d) != nil {
		return "", nil, nil
	}
	c := d.config
	if d.Config != nil {
		c = *d.Config
	}
	plan = strings.TrimSpace(c.SubscriptionTier)

	end := flexTime(c.BillingPeriodEnd)
	if c.CurrentPeriod != nil {
		if e := flexTime(c.CurrentPeriod.End); e != 0 {
			end = e
		}
	}
	limit, hasLimit := c.MonthlyLimit.num()
	used, hasUsed := c.Used.num()
	monthly := hasLimit && hasUsed && limit > 0

	// The answer names a weekly period, and it is the billing period.
	confirmedWeekly := false
	if p := c.CurrentPeriod; p != nil && p.Type == "USAGE_PERIOD_TYPE_WEEKLY" {
		ps, pe := flexTime(p.Start), flexTime(p.End)
		confirmedWeekly = ps != 0 && pe != 0 && ps == flexTime(c.BillingPeriodStart) && pe == flexTime(c.BillingPeriodEnd)
	}

	// The weekly credit window.
	var weekly *float64
	raw := strings.TrimSpace(string(c.CreditUsagePercent))
	switch {
	case raw != "" && raw != "null":
		if f, err := strconv.ParseFloat(strings.Trim(raw, `"`), 64); err == nil {
			weekly = &f
		}
	case !monthly && confirmedWeekly &&
		!grokWritesZeros(c.OnDemandCap, c.OnDemandUsed, c.PrepaidBalance, c.MonthlyLimit, c.Used):
		// xAI leaves a zero out of the answer; with a weekly period
		// named and no sign that zeros are written, the omission is 0.
		zero := 0.0
		weekly = &zero
	}
	if weekly != nil {
		windows = append(windows, Window{Minutes: 10080, UsedPct: pct(*weekly), ResetsAt: end})
	}
	if monthly {
		windows = append(windows, Window{Minutes: 43200, UsedPct: pct(used / limit * 100), ResetsAt: end})
	}

	capV, hasCap := c.OnDemandCap.num()
	spent, hasSpent := c.OnDemandUsed.num()
	bal, hasBal := c.PrepaidBalance.num()
	if hasCap || hasBal {
		extra = &Extra{Enabled: capV > 0 || bal > 0}
		if hasCap && capV > 0 {
			extra.Limit = money(capV)
			if hasSpent {
				extra.Spent = money(spent)
			}
			extra.Currency = "USD"
		}
		if hasBal && bal > 0 {
			extra.Balance = money(bal)
		}
	}
	return plan, windows, extra
}

// grokWritesZeros reports whether any amount in the answer is written as
// exactly zero. If xAI writes zeros, a missing percentage is not a zero.
func grokWritesZeros(vals ...*grokVal) bool {
	for _, v := range vals {
		if f, ok := v.num(); ok && f == 0 {
			return true
		}
	}
	return false
}
