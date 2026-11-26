package router

import (
	"encoding/json"
	"math"
	"os"
	"reflect"
	"sort"
	"testing"
	"time"
)

type scenario struct {
	Name               string   `json:"name"`
	Probe              string   `json:"probe"`
	Stage              string   `json:"stage"`
	Risk               string   `json:"risk"`
	Only               []string `json:"only"`
	PreferFree         bool     `json:"prefer_free"`
	AllowMetered       bool     `json:"allow_metered"`
	AllowFreeReviewers bool     `json:"allow_free_reviewers"`
	SecModels          []string `json:"sec_models"`
	GatewayURL         string   `json:"gateway_url"`
	BuilderFamily      string   `json:"builder_family"`
	Round              int      `json:"round"`
	Surfaces           []string `json:"surfaces"`
	Diff               int      `json:"diff"`
	NoDiscovered       bool     `json:"no_discovered"`
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
}

// TestGoldenMatchesBashRouter runs every scenario through the Go router
// and compares the decision, field by field, with what the bash router
// decided for the same catalog, pools and models.
//
// testdata/golden.json is frozen: the bash router that wrote it was removed
// (the last version is at the legacy-bash-final tag), so it can't be
// regenerated. A new scenario needs its expected decision written by hand
// and checked; a deliberate change in routing updates the affected entries
// the same way.
func TestGoldenMatchesBashRouter(t *testing.T) {
	var scenarios []scenario
	var probes map[string]*Probe
	var disc struct {
		Models []DiscoveredModel `json:"models"`
	}
	var golden map[string]map[string]any
	readJSON(t, "testdata/scenarios.json", &scenarios)
	readJSON(t, "testdata/probes.json", &probes)
	readJSON(t, "testdata/discovered.json", &disc)
	readJSON(t, "testdata/golden.json", &golden)
	cat := DefaultCatalog()

	for _, s := range scenarios {
		t.Run(s.Name, func(t *testing.T) {
			want, ok := golden[s.Name]
			if !ok {
				t.Fatalf("no golden decision for this scenario in testdata/golden.json")
			}
			r := &Router{Catalog: cat, Probe: probes[s.Probe], Discovered: disc.Models}
			if s.NoDiscovered {
				r.Discovered = nil
			}
			surf := s.Surfaces
			if surf == nil {
				surf = []string{"code"}
			}
			got := r.Select(Input{
				Stage: s.Stage, Risk: s.Risk, Round: s.Round, Surfaces: surf,
				DiffLines: s.Diff, BuilderFamily: s.BuilderFamily, OnlyHarnesses: s.Only,
				GatewayURL: s.GatewayURL, AllowMetered: s.AllowMetered, PreferFree: s.PreferFree,
				AllowFreeReviewers: s.AllowFreeReviewers, SecurityModels: s.SecModels, Now: time.Now(),
			})
			b, _ := json.Marshal(got)
			var gotMap map[string]any
			_ = json.Unmarshal(b, &gotMap)

			keys := map[string]bool{}
			for k := range want {
				keys[k] = true
			}
			for k := range gotMap {
				keys[k] = true
			}
			var names []string
			for k := range keys {
				names = append(names, k)
			}
			sort.Strings(names)
			for _, k := range names {
				w, g := want[k], gotMap[k]
				if k == "pool_quota_source" {
					// Added after the bash router; not in the frozen fixture.
					continue
				}
				if k == "reason" {
					ws, _ := w.(string)
					gs, _ := g.(string)
					if ws != gs {
						t.Errorf("reason:\n bash %s\n   go %s", ws, gs)
					}
					continue
				}
				if !same(w, g) {
					t.Errorf("%s: bash %v, go %v", k, w, g)
				}
			}
		})
	}
}

func same(a, b any) bool {
	fa, aok := a.(float64)
	fb, bok := b.(float64)
	if aok && bok {
		return math.Abs(fa-fb) < 1e-9
	}
	return reflect.DeepEqual(a, b)
}
