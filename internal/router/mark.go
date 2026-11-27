package router

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/failsig"
	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// PoolFailureKind classifies a pool failure reason: auth (24 h, or until
// the login is renewed), quota (1 h) or transient (15 min). It returns the
// kind, its TTL in seconds and the used percentage to record.
func PoolFailureKind(reason string) (kind string, ttl int64, used int) {
	switch {
	case failsig.Auth(reason):
		return "auth", 86400, 100
	case failsig.Quota(reason):
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
// each rewrites the whole file. When the lock can't be had (another writer
// held it for the whole 30-second wait, or its directory can't be made),
// the mark is written without it, as the bash engine does: a mark is worth
// more than strict ordering. A writer that raced it in that window can
// lose its own update. A file that does not decode is replaced.
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

// ClearSignals removes failure marks from the signals file, so the router
// uses those pools again at once: the named pools, or with none named,
// every pool mark and every model mark. It returns what it removed (pool
// ids, and "model:<id>" for models), sorted. With dryRun nothing is
// written.
func ClearSignals(path string, pools []string, dryRun bool) ([]string, error) {
	var removed []string
	collect := func(doc map[string]any) {
		removed = removed[:0]
		ps, _ := doc["pools"].(map[string]any)
		if len(pools) == 0 {
			for id := range ps {
				removed = append(removed, id)
			}
			ms, _ := doc["unavailable_models"].(map[string]any)
			for id := range ms {
				removed = append(removed, "model:"+id)
			}
			if !dryRun {
				delete(doc, "pools")
				delete(doc, "unavailable_models")
			}
		} else {
			for _, id := range pools {
				if _, ok := ps[id]; ok {
					removed = append(removed, id)
					if !dryRun {
						delete(ps, id)
					}
				}
			}
		}
		sort.Strings(removed)
	}
	if dryRun {
		doc := map[string]any{}
		if b, err := os.ReadFile(path); err == nil {
			dec := json.NewDecoder(bytes.NewReader(b))
			dec.UseNumber()
			_ = dec.Decode(&doc)
		}
		collect(doc)
		return removed, nil
	}
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	err := updateSignals(path, collect)
	return removed, err
}
