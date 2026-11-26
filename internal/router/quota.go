package router

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Claude has no usage figure AFK can read without the Claude login, and
// AFK never opens a credential file, so the Claude pool is estimated from
// recent local sessions (see ProbePools). Codex writes its own rate limits
// into its session files, which hold no credential; those are read below.

func maxOf(v []float64) float64 {
	m := math.Inf(-1)
	for _, x := range v {
		m = math.Max(m, x)
	}
	return m
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
	best.FetchedEpochRaw = bestAt
	return best
}

// claudeDir is Claude Code's directory: $CLAUDE_CONFIG_DIR when set (as
// Claude Code itself uses it), else ~/.claude.
func claudeDir(e ProbeEnv) string {
	if d := e.getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	return filepath.Join(e.Home, ".claude")
}

// claudeCredsPath is Claude Code's login file: AFK_CLAUDE_CREDS_FILE,
// else .credentials.json in claudeDir. Only its existence and time are
// looked at.
func claudeCredsPath(e ProbeEnv) string {
	if p := e.getenv("AFK_CLAUDE_CREDS_FILE"); p != "" {
		return p
	}
	return filepath.Join(claudeDir(e), ".credentials.json")
}

// codexAuthPath is Codex's login file: AFK_CODEX_AUTH_FILE, then
// $CODEX_HOME/auth.json, then ~/.codex/auth.json, the same place Codex
// itself (and its sessions) use. Only its existence, size and time are
// looked at.
func codexAuthPath(e ProbeEnv) string {
	if p := e.getenv("AFK_CODEX_AUTH_FILE"); p != "" {
		return p
	}
	if h := e.getenv("CODEX_HOME"); h != "" {
		return filepath.Join(h, "auth.json")
	}
	return filepath.Join(e.Home, ".codex", "auth.json")
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
	window := ""
	fullest := -1.0
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
		// The figure is the fuller window's, so its reset and name go
		// with it.
		if *w.UsedPercent > fullest {
			fullest = *w.UsedPercent
			rst = nil
			if w.ResetsAt != nil {
				rst = f64(*w.ResetsAt)
			}
			switch {
			case mins == 300:
				window = "5h"
			case mins == 10080:
				window = "weekly"
			case mins > 0:
				window = "other" // a length AFK doesn't project
			default:
				window = ""
			}
		}
	}
	eff := math.Max(0, math.Min(100, math.Round(maxOf(used))))
	return quota{
		OK: true, Source: "codex_rate_limits", UsedPct: eff,
		FiveHourPct: fh, SevenDayPct: wk, ResetsAtEpoch: rst, PlanType: rl.PlanType, Window: window,
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
