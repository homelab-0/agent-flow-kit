package router

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

// CatalogSchema is the catalog version the router reads.
const CatalogSchema = "afk-benchmark-catalog/3"

//go:embed benchmarks.json
var defaultCatalog []byte

// Benchmark is one score for one task class.
type Benchmark struct {
	Score       *float64 `json:"score"`
	Name        string   `json:"benchmark"`
	Source      string   `json:"source,omitempty"`
	Basis       string   `json:"basis,omitempty"`
	SyncedAt    *string  `json:"synced_at,omitempty"`
	SyncedEpoch int64    `json:"synced_epoch,omitempty"`
	Live        bool     `json:"live,omitempty"`

	scoreText string
}

// UnmarshalJSON keeps the score's literal text too, so a reason reads
// "95.0" when the catalog says 95.0, as the bash router's does.
func (b *Benchmark) UnmarshalJSON(data []byte) error {
	type plain Benchmark
	var p plain
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	var raw struct {
		Score json.RawMessage `json:"score"`
	}
	_ = json.Unmarshal(data, &raw)
	*b = Benchmark(p)
	if p.Score != nil {
		b.scoreText = string(raw.Score)
	}
	return nil
}

// ScoreText is the score as the catalog wrote it.
func (b Benchmark) ScoreText() string {
	if b.scoreText != "" {
		return b.scoreText
	}
	if b.Score == nil {
		return ""
	}
	return strconv.FormatFloat(*b.Score, 'f', -1, 64)
}

// Candidate is one model a CLI can run, as the catalog describes it.
type Candidate struct {
	ID                  string               `json:"id"`
	Harness             string               `json:"harness"`
	LaunchClass         string               `json:"launch_class"`
	EntitlementPool     string               `json:"entitlement_pool"`
	CostClass           string               `json:"cost_class,omitempty"`
	IsFree              *bool                `json:"is_free,omitempty"`
	Tier                string               `json:"tier,omitempty"`
	Model               string               `json:"model"`
	CanonicalModel      string               `json:"canonical_model"`
	ModelFamily         string               `json:"model_family"`
	Effort              string               `json:"effort"`
	SupportedEfforts    []string             `json:"supported_efforts,omitempty"`
	WindowTokens        *float64             `json:"window_tokens,omitempty"`
	RequiresGateway     bool                 `json:"requires_gateway,omitempty"`
	RequiresEntitlement string               `json:"requires_entitlement,omitempty"`
	SpecialistDomain    string               `json:"specialist_domain,omitempty"`
	FrontierOnly        bool                 `json:"frontier_only,omitempty"`
	ScopedQuota         string               `json:"scoped_quota,omitempty"`
	BridgedOAuth        bool                 `json:"is_bridged_oauth,omitempty"`
	Benchmarks          map[string]Benchmark `json:"benchmarks"`
}

// PoolMeta is what the catalog says about a subscription pool.
type PoolMeta struct {
	Provider        string   `json:"provider"`
	CostClass       string   `json:"cost_class"`
	PoolTier        string   `json:"pool_tier"`
	FiveHourSession *float64 `json:"five_hour_session_capacity"`
}

// Catalog is the benchmark catalog: candidates and their pools.
type Catalog struct {
	Schema     string              `json:"schema"`
	UpdatedAt  string              `json:"updated_at"`
	Candidates []Candidate         `json:"candidates"`
	Pools      map[string]PoolMeta `json:"entitlement_pools"`
	// Path is where it was read from ("" for the built-in catalog).
	Path string `json:"-"`
}

// ParseCatalog reads a catalog document.
func ParseCatalog(b []byte) (*Catalog, error) {
	var c Catalog
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("benchmark catalog: %w", err)
	}
	return &c, nil
}

// DefaultCatalog is the catalog built into the binary.
func DefaultCatalog() *Catalog {
	c, err := ParseCatalog(defaultCatalog)
	if err != nil {
		panic("built-in catalog: " + err.Error())
	}
	return c
}

// LoadCatalog finds the catalog to route with: AFK_ROUTER_BENCHMARKS_FILE,
// then the synced one at ~/.config/afk/benchmarks.json when it has the
// current schema, then the built-in one.
func LoadCatalog(home string, getenv func(string) string) (*Catalog, error) {
	if p := getenv("AFK_ROUTER_BENCHMARKS_FILE"); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			c, err := ParseCatalog(b)
			if err != nil {
				return nil, err
			}
			c.Path = p
			return c, nil
		}
	}
	if home != "" {
		p := filepath.Join(home, ".config", "afk", "benchmarks.json")
		if b, err := os.ReadFile(p); err == nil {
			if c, err := ParseCatalog(b); err == nil && c.Schema == CatalogSchema {
				c.Path = p
				return c, nil
			}
		}
	}
	return DefaultCatalog(), nil
}

// ModelsFor returns, for each installed CLI the catalog says serves the
// model (by its CLI name or canonical name), that CLI's name for it.
func (c *Catalog) ModelsFor(model string, installed []string) map[string]string {
	ok := map[string]bool{}
	for _, h := range installed {
		ok[h] = true
	}
	out := map[string]string{}
	for _, cand := range c.Candidates {
		if (cand.Model == model || cand.CanonicalModel == model) && ok[cand.Harness] {
			if _, seen := out[cand.Harness]; !seen {
				out[cand.Harness] = cand.Model
			}
		}
	}
	return out
}
