package router

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/statefile"
)

// The kinds of pool failure, and how long each keeps the pool aside.
var (
	markAuthRE  = regexp.MustCompile(`(401|unauthorized|token_revoked|invalidated\s+oauth|refresh\s+token|not\s+logged\s+in)`)
	markQuotaRE = regexp.MustCompile(`(429|rate_limit|rate\s+limit|quota|out_of_credits|spend_limit|exhausted)`)
)

// PoolFailureKind classifies a pool failure reason: auth (24 h, or until
// the login is renewed), quota (1 h) or transient (15 min). It returns the
// kind, its TTL in seconds and the used percentage to record.
func PoolFailureKind(reason string) (kind string, ttl int64, used int) {
	r := strings.ToLower(reason)
	switch {
	case markAuthRE.MatchString(r):
		return "auth", 86400, 100
	case markQuotaRE.MatchString(r):
		return "quota", 3600, 100
	}
	return "transient", 900, 95
}

// MarkPoolDegraded records a failure for a pool in the signals file, so the
// router sets the pool aside (afk_router_mark_pool_degraded). Other entries
// in the file are kept as they are.
func MarkPoolDegraded(path, pool, reason string, now time.Time) error {
	if pool == "" {
		return nil
	}
	if reason == "" {
		reason = "runtime_failure"
	}
	kind, ttl, used := PoolFailureKind(reason)
	return updateSignals(path, func(doc map[string]any) {
		pools, _ := doc["pools"].(map[string]any)
		if pools == nil {
			pools = map[string]any{}
		}
		entry, _ := pools[pool].(map[string]any)
		if entry == nil {
			entry = map[string]any{}
		}
		entry["used_pct"] = used
		entry["degraded_reason"] = reason
		entry["degraded_kind"] = kind
		entry["updated_at"] = now.UTC().Format("2006-01-02T15:04:05Z")
		entry["updated_epoch"] = now.Unix()
		entry["ttl_sec"] = ttl
		pools[pool] = entry
		doc["pools"] = pools
	})
}

// MarkModelUnavailable sets one model aside for an hour, without touching
// the rest of its pool (afk_router_mark_model_unavailable).
func MarkModelUnavailable(path, model, reason string, now time.Time) error {
	if model == "" {
		return nil
	}
	if reason == "" {
		reason = "model_unavailable"
	}
	return updateSignals(path, func(doc map[string]any) {
		models, _ := doc["unavailable_models"].(map[string]any)
		if models == nil {
			models = map[string]any{}
		}
		models[model] = map[string]any{
			"reason": reason, "updated_at": now.UTC().Format("2006-01-02T15:04:05Z"),
			"updated_epoch": now.Unix(), "ttl_sec": 3600,
		}
		doc["unavailable_models"] = models
	})
}

// updateSignals is a read-modify-write of the signals file under its lock
// (the same lock the bash engine takes): several runs may mark at once, and
// each rewrites the whole file. A file that does not decode is replaced.
func updateSignals(path string, change func(map[string]any)) error {
	lock, err := acquireSignals(path)
	if err == nil {
		defer lock.Release()
	}
	doc := map[string]any{}
	if b, err := os.ReadFile(path); err == nil {
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		var cur map[string]any
		if dec.Decode(&cur) == nil && cur != nil {
			doc = cur
		}
	}
	change(doc)
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	return statefile.WriteJSON(path, append(b, '\n'))
}

func acquireSignals(path string) (*statefile.Lock, error) {
	dir := path + ".lock"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return statefile.Acquire(dir, 30*time.Second, 10*time.Second)
}
