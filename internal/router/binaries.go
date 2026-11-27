package router

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

// VerifyBinaries returns an Installed function for ProbeEnv: a CLI counts
// when it is found and answers --version. Answers are remembered in
// ~/.config/afk/harness-bin-cache.json, keyed by path and modification
// time, for five minutes (thirty seconds for a failure, so a CLI caught
// mid-update is soon tried again). Set AFK_ROUTER_BIN_CACHE_SEC=0 to
// check every time.
func VerifyBinaries(ctx context.Context, he harness.Env, getenv func(string) string) func(string) bool {
	cachePath := filepath.Join(he.Home, ".config", "afk", "harness-bin-cache.json")
	if p := getenv("AFK_ROUTER_BIN_CACHE_FILE"); p != "" {
		cachePath = p
	}
	ttl := envInt(getenv("AFK_ROUTER_BIN_CACHE_SEC"), 300)
	failTTL := envInt(getenv("AFK_ROUTER_BIN_FAIL_CACHE_SEC"), 30)

	type entry struct {
		OK    bool   `json:"ok"`
		At    int64  `json:"at"`
		Mtime string `json:"mtime"`
	}
	var mu sync.Mutex
	cache := map[string]entry{}
	if ttl > 0 {
		_ = readJSONFile(cachePath, &cache)
		if cache == nil {
			cache = map[string]entry{}
		}
	}
	return func(name string) bool {
		a, ok := harness.Lookup(name)
		if !ok {
			return false
		}
		bin := harness.Locate(he, a)
		if bin == "" {
			return false
		}
		mt := ""
		if fi, err := os.Stat(bin); err == nil {
			// Full precision: a CLI replaced within the same second
			// is checked again.
			mt = strconv.FormatInt(fi.ModTime().UnixNano(), 10)
		}
		now := time.Now().Unix()
		mu.Lock()
		hit, found := cache[bin]
		mu.Unlock()
		if ttl > 0 && found && hit.Mtime == mt {
			limit := int64(ttl)
			if !hit.OK {
				limit = int64(failTTL)
			}
			if now-hit.At < limit {
				return hit.OK
			}
		}
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(cctx, bin, "--version")
		cmd.WaitDelay = time.Second
		answered := cmd.Run() == nil
		// A check cut short because the caller gave up says nothing
		// about the CLI; don't remember it.
		if ctx.Err() != nil {
			return answered
		}
		if ttl > 0 {
			mu.Lock()
			// Re-read so CLIs checked by another afk at the same time are kept.
			cur := map[string]entry{}
			_ = readJSONFile(cachePath, &cur)
			if cur == nil {
				cur = map[string]entry{}
			}
			cur[bin] = entry{OK: answered, At: now, Mtime: mt}
			cache = cur
			if b, err := json.Marshal(cur); err == nil {
				_ = writeFileAtomic(cachePath, b, 0o644)
			}
			mu.Unlock()
		}
		return answered
	}
}

func envInt(v string, def int) int {
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return def
	}
	return n
}
