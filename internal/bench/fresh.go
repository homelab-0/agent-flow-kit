package bench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Env is what the freshness check reads.
type Env struct {
	Home   string
	Getenv func(string) string
	Now    time.Time
}

func (e Env) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func (e Env) now() time.Time {
	if e.Now.IsZero() {
		return time.Now()
	}
	return e.Now
}

// CatalogPath is the synced catalog: ~/.config/afk/benchmarks.json.
func CatalogPath(home string) string {
	return filepath.Join(home, ".config", "afk", "benchmarks.json")
}

func (e Env) seconds(key string, def int64) time.Duration {
	v, err := strconv.ParseInt(e.getenv(key), 10, 64)
	if err != nil || v < 0 {
		v = def
	}
	return time.Duration(v) * time.Second
}

// Due reports whether the synced catalog should be refreshed: it is
// missing, on an older schema, has no measured score, or is older than
// AFK_BENCHMARK_TTL_SEC (default a day), and no attempt was made in the
// last AFK_BENCHMARK_RETRY_SEC (default 15 minutes). A sync that fails, or
// reaches no board, leaves the catalog as it was, so its age alone would
// otherwise start another sync on every route.
//
// Never due when AFK_ROUTER_BENCHMARKS_FILE names a catalog of your own or
// AFK_SKIP_BENCHMARK_AUTOSYNC=1.
func Due(e Env) bool {
	if e.getenv("AFK_ROUTER_BENCHMARKS_FILE") != "" || e.getenv("AFK_SKIP_BENCHMARK_AUTOSYNC") == "1" || e.Home == "" {
		return false
	}
	now := e.now()
	ttl := e.seconds("AFK_BENCHMARK_TTL_SEC", 86400)
	retry := e.seconds("AFK_BENCHMARK_RETRY_SEC", 900)
	cat := CatalogPath(e.Home)
	if fi, err := os.Stat(cat); err == nil {
		// A file dated in the future (a volume restored from a skewed
		// clock) is stale, not fresh until the clock catches up.
		age := now.Sub(fi.ModTime())
		if age >= 0 && age < ttl && measuredScores(cat) > 0 {
			return false
		}
	}
	if fi, err := os.Stat(cat + ".sync-attempt"); err == nil {
		age := now.Sub(fi.ModTime())
		if age >= 0 && age < retry {
			return false
		}
	}
	return true
}

func measuredScores(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	var doc struct {
		Schema  string `json:"schema"`
		Receipt struct {
			Live int `json:"live_scores"`
		} `json:"sync_receipt"`
	}
	if json.Unmarshal(b, &doc) != nil || doc.Schema != SchemaCatalog {
		return 0
	}
	return doc.Receipt.Live
}

// AutoSync is the automatic refresh: when Due, one process syncs (under
// the same lock and attempt marker the bash engine uses) and every other
// one carries on with the catalog it has. It reports whether it synced.
func AutoSync(ctx context.Context, e Env, sync func(context.Context) int) bool {
	if !Due(e) {
		return false
	}
	cat := CatalogPath(e.Home)
	marker := cat + ".sync-attempt"
	if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
		return false
	}
	lock := marker + ".lock"
	if err := os.Mkdir(lock, 0o755); err != nil {
		// A lock left by a killed sync is cleared after five minutes.
		if fi, err := os.Stat(lock); err == nil && time.Since(fi.ModTime()) > 5*time.Minute {
			_ = os.Remove(lock)
		}
		return false
	}
	defer os.Remove(lock)
	// Another process may have finished a sync between the check and the
	// lock: look again before starting another.
	e.Now = time.Now()
	if !Due(e) {
		return false
	}
	now := time.Now()
	if err := os.WriteFile(marker, nil, 0o644); err == nil {
		_ = os.Chtimes(marker, now, now)
	}
	sync(ctx)
	return true
}
