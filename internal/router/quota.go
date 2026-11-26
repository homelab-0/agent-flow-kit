package router

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ClaudeUsageURL is Anthropic's usage endpoint for a Claude plan login.
const ClaudeUsageURL = "https://api.anthropic.com/api/oauth/usage"

// --- Claude: the OAuth usage API --------------------------------------------

// probeClaudeQuota asks Anthropic how much of the 5-hour and weekly windows
// the Claude login has used. The answer is cached for two minutes in
// ~/.config/afk/live-quota-cache.json (mode 600), which holds usage
// figures only. The token is read to make the request and goes nowhere
// else.
func probeClaudeQuota(ctx context.Context, e ProbeEnv) quota {
	if f := e.getenv("AFK_CLAUDE_USAGE_FIXTURE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return quota{}
		}
		return parseClaudeUsage(b)
	}
	if !e.Live {
		return quota{}
	}
	creds := e.path("AFK_CLAUDE_CREDS_FILE", ".claude/.credentials.json")
	if !exists(creds) {
		return quota{}
	}
	cache := e.path("AFK_QUOTA_CACHE_FILE", ".config/afk/live-quota-cache.json")
	now := e.Now.Unix()
	login := loginGeneration(creds)
	var cached struct {
		Claude *struct {
			Fetched int64  `json:"fetched_epoch"`
			Login   string `json:"login"`
			Data    quota  `json:"data"`
		} `json:"claude"`
	}
	// A reading belongs to the login it was made with: signing in again,
	// or as someone else, starts afresh.
	if readJSONFile(cache, &cached) && cached.Claude != nil && cached.Claude.Fetched > 0 &&
		cached.Claude.Login == login && now-cached.Claude.Fetched < 120 {
		return cached.Claude.Data
	}
	var c struct {
		OAuth *struct {
			Access string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if !readJSONFile(creds, &c) || c.OAuth == nil || c.OAuth.Access == "" {
		return quota{}
	}
	url := e.ClaudeUsageURL
	if url == "" {
		url = ClaudeUsageURL
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return quota{}
	}
	req.Header.Set("Authorization", "Bearer "+c.OAuth.Access)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	resp, err := e.HTTP.Do(req)
	if err != nil {
		return quota{}
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return quota{}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return quota{}
	}
	q := parseClaudeUsage(body)
	if q.OK {
		writeQuotaCache(cache, "claude", now, login, q)
	}
	return q
}

// loginGeneration identifies a credential file's current contents without
// holding anything from them: a hash of its path, size and modification
// time. It changes whenever the login is renewed or replaced. A rewrite to
// the same size within one tick of the filesystem clock would look the
// same; the cache lasts two minutes, so the worst case is one stale
// reading. The file's contents are deliberately not hashed into the
// cache, since they are the token.
func loginGeneration(path string) string {
	fi, err := os.Stat(path)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%d|%d", path, fi.Size(), fi.ModTime().UnixNano())))
	return hex.EncodeToString(sum[:8])
}

type usageWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type usageLimit struct {
	Active   bool     `json:"is_active"`
	Group    string   `json:"group"`
	Kind     string   `json:"kind"`
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Label    string   `json:"label"`
	Percent  *float64 `json:"percent"`
	Severity any      `json:"severity"`
	ResetsAt *string  `json:"resets_at"`
}

// parseClaudeUsage reads the usage API's answer the way the bash probe
// does: the larger of the 5-hour and weekly use, with the Fable weekly
// quota kept apart, and the weekly figure discounted while extra usage is
// on and has room.
func parseClaudeUsage(b []byte) quota {
	var raw map[string]json.RawMessage
	if json.Unmarshal(b, &raw) != nil {
		return quota{}
	}
	_, hasSD := raw["seven_day"]
	_, hasFH := raw["five_hour"]
	_, hasLim := raw["limits"]
	if !hasSD && !hasFH && !hasLim {
		return quota{}
	}
	var u struct {
		FiveHour   *usageWindow `json:"five_hour"`
		SevenDay   *usageWindow `json:"seven_day"`
		SevenFable *usageWindow `json:"seven_day_fable"`
		Limits     []usageLimit `json:"limits"`
		Extra      *struct {
			Enabled     bool     `json:"is_enabled"`
			Utilization *float64 `json:"utilization"`
		} `json:"extra_usage"`
	}
	if json.Unmarshal(b, &u) != nil {
		return quota{}
	}
	fh := 0.0
	haveFH := u.FiveHour != nil && u.FiveHour.Utilization != nil
	if haveFH {
		fh = *u.FiveHour.Utilization
	}
	kindOr := func(l usageLimit, def string) string {
		if l.Kind == "" {
			return def
		}
		return l.Kind
	}
	isFable := func(l usageLimit) bool {
		name := l.Kind
		for _, n := range []string{l.ID, l.Name, l.Label} {
			if name == "" {
				name = n
			}
		}
		return strings.Contains(strings.ToLower(name), "fable")
	}
	var weekly, fable, other []float64
	for _, l := range u.Limits {
		if l.Percent == nil {
			continue
		}
		if l.Active && l.Group == "weekly" && kindOr(l, "weekly_all") == "weekly_all" {
			weekly = append(weekly, *l.Percent)
		}
		if l.Group == "scoped_weekly" || l.Kind == "weekly_scoped" || isFable(l) {
			fable = append(fable, *l.Percent)
		}
		group := l.Group
		if group == "" {
			group = "weekly"
		}
		if l.Active && group != "scoped_weekly" && kindOr(l, "weekly_all") != "weekly_scoped" && !strings.Contains(strings.ToLower(l.Kind), "fable") {
			other = append(other, *l.Percent)
		}
	}
	// No figure at all (nulls everywhere) is not a reading of 0%: the
	// activity estimate is used instead. An explicit 0 is a reading.
	haveSD := u.SevenDay != nil && u.SevenDay.Utilization != nil
	if !haveFH && !haveSD && len(weekly) == 0 && len(other) == 0 {
		return quota{}
	}
	wk := 0.0
	switch {
	case u.SevenDay != nil && u.SevenDay.Utilization != nil:
		wk = *u.SevenDay.Utilization
	case len(weekly) > 0:
		wk = maxOf(weekly)
	}
	var fableWk *float64
	if len(fable) > 0 {
		fableWk = f64(math.Round(maxOf(fable)))
	} else if u.SevenFable != nil && u.SevenFable.Utilization != nil {
		fableWk = f64(math.Round(*u.SevenFable.Utilization))
	}
	// Extra usage softens the weekly figure only while it has room; with
	// no utilization reported it is taken as full.
	extraOK := u.Extra != nil && u.Extra.Enabled && u.Extra.Utilization != nil && *u.Extra.Utilization < 90
	var eff float64
	if extraOK {
		eff = math.Round(math.Max(fh, wk*0.80))
	} else {
		o := 0.0
		if len(other) > 0 {
			o = maxOf(other)
		}
		eff = math.Round(maxOf([]float64{fh, wk, o}))
	}
	eff = math.Max(0, math.Min(100, eff))
	q := quota{
		OK: true, Source: "anthropic_oauth_api", UsedPct: eff,
		FiveHourPct: f64(math.Round(fh)), SevenDayPct: f64(math.Round(wk)), FableWeeklyPct: fableWk,
		ExtraUsageOn: u.Extra != nil && u.Extra.Enabled,
	}
	if u.SevenDay != nil && u.SevenDay.ResetsAt != nil {
		q.ResetsAt = u.SevenDay.ResetsAt
	} else if len(u.Limits) > 0 {
		q.ResetsAt = u.Limits[0].ResetsAt
	}
	return q
}

func maxOf(v []float64) float64 {
	m := math.Inf(-1)
	for _, x := range v {
		m = math.Max(m, x)
	}
	return m
}

func writeQuotaCache(path, key string, now int64, login string, q quota) {
	cur := map[string]json.RawMessage{}
	_ = readJSONFile(path, &cur)
	if cur == nil {
		cur = map[string]json.RawMessage{}
	}
	entry, err := json.Marshal(map[string]any{"fetched_epoch": now, "login": login, "data": q})
	if err != nil {
		return
	}
	cur[key] = entry
	b, err := json.Marshal(cur)
	if err != nil {
		return
	}
	_ = writeFileAtomic(path, b, 0o600)
}

// writeFileAtomic writes through a temporary file and a rename.
func writeFileAtomic(path string, b []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// --- Codex: the rate limits it writes into its session files ----------------

// probeCodexQuota reads the newest unexpired rate-limit snapshot Codex
// wrote into its rollout files. No network.
func probeCodexQuota(e ProbeEnv) quota {
	dir := codexSessionsDir(e)
	// WalkDir doesn't follow a symlinked root; resolve it first.
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		dir = r
	}
	var files []string
	_ = filepath.WalkDir(dir, func(p string, de os.DirEntry, err error) error {
		// Regular files only: opening a named pipe could block.
		if err == nil && de.Type().IsRegular() && strings.HasPrefix(de.Name(), "rollout-") && strings.HasSuffix(de.Name(), ".jsonl") {
			files = append(files, p)
		}
		return nil
	})
	// The eight newest sessions by name (the names carry the start time).
	sort.SliceStable(files, func(i, j int) bool { return filepath.Base(files[i]) < filepath.Base(files[j]) })
	if len(files) > 8 {
		files = files[len(files)-8:]
	}
	// An older session can still write newer rate limits, so the newest
	// reading wins by when it was observed, not by file name.
	now := e.Now.Unix()
	var best quota
	var bestAt int64 = -1
	for _, f := range files {
		q, at, ok := lastCodexReading(f, now)
		if ok && at > bestAt {
			best, bestAt = q, at
		}
	}
	if bestAt < 0 {
		return quota{}
	}
	return best
}

// codexSessionsDir is where Codex keeps its sessions:
// AFK_CODEX_SESSIONS_DIR, then $CODEX_HOME/sessions, then ~/.codex/sessions.
func codexSessionsDir(e ProbeEnv) string {
	if d := e.getenv("AFK_CODEX_SESSIONS_DIR"); d != "" {
		return d
	}
	if h := e.getenv("CODEX_HOME"); h != "" {
		return filepath.Join(h, "sessions")
	}
	return filepath.Join(e.Home, ".codex", "sessions")
}

// maxRecord bounds one rollout line; a longer one is skipped, and reading
// carries on after it.
const maxRecord = 16 << 20

// lastCodexReading returns the last usable rate-limit reading in a rollout
// file and when it was observed (the record's timestamp, else the file's
// modification time).
func lastCodexReading(path string, now int64) (quota, int64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return quota{}, 0, false
	}
	defer f.Close()
	fileTime := int64(0)
	if fi, err := f.Stat(); err == nil {
		fileTime = fi.ModTime().Unix()
	}
	var best quota
	var bestAt int64
	found := false
	r := bufio.NewReaderSize(f, 64*1024)
	var line []byte
	tooLong := false
	for {
		chunk, isPrefix, err := r.ReadLine()
		if err != nil {
			break
		}
		if !tooLong {
			line = append(line, chunk...)
			if len(line) > maxRecord {
				tooLong, line = true, line[:0]
			}
		}
		if isPrefix {
			continue
		}
		if !tooLong && bytes.Contains(line, []byte(`"rate_limits"`)) {
			if q, ok := parseCodexRateLimits(line, now); ok {
				at := recordTime(line)
				if at == 0 {
					at = fileTime
				}
				best, bestAt, found = q, at, true
			}
		}
		line, tooLong = line[:0], false
	}
	return best, bestAt, found
}

// recordTime reads a record's top-level "timestamp", if any.
func recordTime(line []byte) int64 {
	var v struct {
		Timestamp string `json:"timestamp"`
	}
	if json.Unmarshal(line, &v) != nil || v.Timestamp == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, v.Timestamp)
	if err != nil {
		return 0
	}
	return t.Unix()
}

type rateWindow struct {
	UsedPercent   *float64 `json:"used_percent"`
	WindowMinutes *float64 `json:"window_minutes"`
	ResetsAt      *float64 `json:"resets_at"`
}

type rateLimits struct {
	Primary   *rateWindow `json:"primary"`
	Secondary *rateWindow `json:"secondary"`
	PlanType  *string     `json:"plan_type"`
}

// parseCodexRateLimits finds the last rate_limits object anywhere in the
// line and reads its unexpired windows.
func parseCodexRateLimits(line []byte, now int64) (quota, bool) {
	var v any
	if json.Unmarshal(line, &v) != nil {
		return quota{}, false
	}
	var found any
	var walk func(x any)
	walk = func(x any) {
		switch t := x.(type) {
		case map[string]any:
			if rl, ok := t["rate_limits"]; ok {
				found = rl
			}
			keys := make([]string, 0, len(t))
			for k := range t {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				walk(t[k])
			}
		case []any:
			for _, y := range t {
				walk(y)
			}
		}
	}
	walk(v)
	if found == nil {
		return quota{}, false
	}
	b, _ := json.Marshal(found)
	var rl rateLimits
	if json.Unmarshal(b, &rl) != nil {
		return quota{}, false
	}
	var wins []rateWindow
	for _, w := range []*rateWindow{rl.Primary, rl.Secondary} {
		if w == nil || w.UsedPercent == nil {
			continue
		}
		if w.ResetsAt != nil && int64(*w.ResetsAt) <= now {
			continue
		}
		wins = append(wins, *w)
	}
	if len(wins) == 0 {
		return quota{}, false
	}
	var used []float64
	var fh, wk, rst *float64
	for _, w := range wins {
		used = append(used, *w.UsedPercent)
		mins := 0.0
		if w.WindowMinutes != nil {
			mins = *w.WindowMinutes
		}
		if mins < 1000 && fh == nil {
			fh = f64(math.Round(*w.UsedPercent))
		}
		if mins >= 1000 && wk == nil {
			wk = f64(math.Round(*w.UsedPercent))
		}
		if w.ResetsAt != nil && (rst == nil || *w.ResetsAt < *rst) {
			rst = f64(*w.ResetsAt)
		}
	}
	eff := math.Max(0, math.Min(100, math.Round(maxOf(used))))
	return quota{
		OK: true, Source: "codex_rate_limits", UsedPct: eff,
		FiveHourPct: fh, SevenDayPct: wk, ResetsAtEpoch: rst, PlanType: rl.PlanType,
	}, true
}

// --- the model gateway ------------------------------------------------------

// probeGateway asks the gateway which models it serves. Off line, or not
// configured, its models are not candidates.
func probeGateway(ctx context.Context, e ProbeEnv) HarnessState {
	gw := HarnessState{}
	if e.GatewayURL == "" {
		return gw
	}
	if !e.Live {
		return gw
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(e.GatewayURL, "/")+"/v1/models", nil)
	if err != nil {
		return gw
	}
	resp, err := e.HTTP.Do(req)
	if err != nil {
		return gw
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return gw
	}
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&body) != nil || body.Data == nil {
		return gw
	}
	gw.Online = true
	gw.Models = []string{}
	for _, m := range body.Data {
		gw.Models = append(gw.Models, m.ID)
	}
	return gw
}
