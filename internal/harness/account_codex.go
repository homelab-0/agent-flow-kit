package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os/exec"
	"time"
)

// Codex CLI (checked against 0.172.0).
//
// `codex app-server --listen stdio://` speaks JSON-RPC, one document per
// line. `account/rateLimits/read` gives the plan, its usage windows and
// the credit balance, and `model/list` the account's models. Neither
// starts a session or spends quota. When the app server doesn't answer,
// the models come from `codex debug models`.
type codexReporter struct{}

func init() { registerReporter("codex", codexReporter{}) }

func (codexReporter) Report(ctx context.Context, _ Env, bin string) Account {
	rep, _ := codexAppServer(ctx, bin)
	if !rep.ModelsKnown {
		a, _ := Lookup("codex")
		rep.Models, rep.ModelsKnown = listModels(ctx, bin, a.Manifest.ModelList)
	}
	if len(rep.Windows) == 0 {
		rep.UsageNote = "Codex didn't report its limits"
	}
	return rep
}

// codexAppServer asks the app server for the rate limits and the models.
func codexAppServer(ctx context.Context, bin string) (Account, bool) {
	var rep Account
	cmd := exec.CommandContext(ctx, bin, "app-server", "--listen", "stdio://")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return rep, false
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return rep, false
	}
	cmd.WaitDelay = time.Second
	if cmd.Start() != nil {
		return rep, false
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	for _, l := range []string{
		`{"id":1,"method":"initialize","params":{"clientInfo":{"name":"afk","version":"1"}}}`,
		`{"method":"initialized"}`,
		`{"id":2,"method":"account/rateLimits/read"}`,
		`{"id":3,"method":"model/list","params":{}}`,
	} {
		if _, err := io.WriteString(stdin, l+"\n"); err != nil {
			return rep, false
		}
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64<<10), 8<<20)
	got := 0
	for got < 2 && sc.Scan() {
		var msg struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if json.Unmarshal(sc.Bytes(), &msg) != nil {
			continue
		}
		switch msg.ID {
		case 2:
			got++
			ParseCodexRateLimits(msg.Result, &rep)
		case 3:
			got++
			ParseCodexModels(msg.Result, &rep)
		}
	}
	return rep, got > 0
}

// ParseCodexRateLimits reads an account/rateLimits/read result into rep.
// The account id in the same document is not decoded.
func ParseCodexRateLimits(result []byte, rep *Account) {
	type window struct {
		UsedPercent        *float64 `json:"usedPercent"`
		WindowDurationMins int      `json:"windowDurationMins"`
		ResetsAt           int64    `json:"resetsAt"`
	}
	var d struct {
		RateLimits struct {
			PlanType  string  `json:"planType"`
			Primary   *window `json:"primary"`
			Secondary *window `json:"secondary"`
			Credits   *struct {
				HasCredits bool   `json:"hasCredits"`
				Unlimited  bool   `json:"unlimited"`
				Balance    string `json:"balance"`
			} `json:"credits"`
		} `json:"rateLimits"`
	}
	if json.Unmarshal(result, &d) != nil {
		return
	}
	rep.Plan = d.RateLimits.PlanType
	for _, w := range []*window{d.RateLimits.Primary, d.RateLimits.Secondary} {
		if w == nil || w.UsedPercent == nil {
			continue
		}
		rep.Windows = append(rep.Windows, Window{Minutes: w.WindowDurationMins, UsedPct: *w.UsedPercent, ResetsAt: w.ResetsAt})
	}
	if c := d.RateLimits.Credits; c != nil {
		rep.Extra = &Extra{Enabled: c.HasCredits || c.Unlimited, Unlimited: c.Unlimited, Balance: c.Balance}
	}
}

// ParseCodexModels reads a model/list result into rep.
func ParseCodexModels(result []byte, rep *Account) {
	var d struct {
		Data []struct {
			ID        string `json:"id"`
			Model     string `json:"model"`
			Hidden    bool   `json:"hidden"`
			IsDefault bool   `json:"isDefault"`
		} `json:"data"`
	}
	if json.Unmarshal(result, &d) != nil {
		return
	}
	for _, m := range d.Data {
		name := m.Model
		if name == "" {
			name = m.ID
		}
		if m.Hidden || !modelNameRE.MatchString(name) {
			continue
		}
		rep.Models = append(rep.Models, name)
		if m.IsDefault {
			rep.DefaultModel = name
		}
	}
	rep.ModelsKnown = len(rep.Models) > 0
}
