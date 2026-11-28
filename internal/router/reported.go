package router

import (
	"regexp"
	"strings"
)

// A CLI that reported its models (HarnessState.ModelsKnown) is routed
// from that list: a catalog model it didn't list is not offered on it,
// and a model it listed that the catalog doesn't know is offered without
// a benchmark score. A CLI that reported nothing is routed from the
// catalog alone, as before.

// planPool is the plan pool each CLI's own models draw on.
var planPool = map[string]string{
	"claude": "anthropic-max", "codex": "openai-plus", "grok": "xai-grok",
	"agy": "antigravity-pool", "opencode": "opencode-free",
}

// reEffortTier is the effort tier some CLIs put at the end of a model
// name (Antigravity: gemini-4-hydrogen-high).
var reEffortTier = regexp.MustCompile(`-(minimal|low|medium|high|xhigh|max)$`)

// baseModel is a reported model name without its effort tier, and the
// tier ("" when it has none).
func baseModel(name string) (base, effort string) {
	if m := reEffortTier.FindStringSubmatch(name); m != nil {
		return strings.TrimSuffix(name, m[0]), m[1]
	}
	return name, ""
}

// modelReported says whether a CLI's reported list has the model: by its
// name, or by its name with an effort tier.
func modelReported(list []string, model string) bool {
	want, _ := baseModel(model)
	for _, m := range list {
		if m == model {
			return true
		}
		if b, _ := baseModel(m); b == want {
			return true
		}
	}
	return false
}

// native reports whether a candidate runs on its CLI's own account (not
// through a gateway or a local engine), so that CLI's list covers it.
func native(c Candidate) bool {
	return !c.RequiresGateway && c.LaunchClass != LocalLaunch && !strings.HasSuffix(c.LaunchClass, "-gateway")
}

// withReported applies what the CLIs reported to the candidates: it drops
// the native ones their CLI didn't list and adds the listed models no
// candidate covers.
func withReported(cands []Candidate, probe *Probe) []Candidate {
	if probe == nil {
		return cands
	}
	out := make([]Candidate, 0, len(cands))
	covered := map[string]bool{} // harness + "\x00" + base model
	for _, c := range cands {
		hs := probe.Harnesses[c.Harness]
		if native(c) && hs.ModelsKnown && !modelReported(hs.Models, c.Model) {
			continue
		}
		if native(c) {
			b, _ := baseModel(c.Model)
			covered[c.Harness+"\x00"+b] = true
		}
		out = append(out, c)
	}
	for _, h := range probeHarnesses {
		hs := probe.Harnesses[h]
		pool := planPool[h]
		if !hs.ModelsKnown || pool == "" {
			continue
		}
		efforts := map[string][]string{}
		var order []string
		for _, m := range hs.Models {
			b, e := baseModel(m)
			if _, seen := efforts[b]; !seen {
				order = append(order, b)
				efforts[b] = nil
			}
			if e != "" {
				efforts[b] = append(efforts[b], e)
			}
		}
		// A CLI that names effort tiers in its model names sets the
		// effort that way only: its models without a tier have none.
		tiered := false
		for _, e := range efforts {
			tiered = tiered || len(e) > 0
		}
		for _, b := range order {
			if covered[h+"\x00"+b] {
				continue
			}
			if tiered && efforts[b] == nil {
				efforts[b] = []string{}
			}
			c := Candidate{
				ID: h + ":" + b, Harness: h, LaunchClass: h + "-native", EntitlementPool: pool,
				Model: b, ModelFamily: familyOf(b), Effort: "medium", SupportedEfforts: efforts[b],
				Benchmarks: map[string]Benchmark{}, unrated: true,
			}
			if pool == "opencode-free" {
				free := true
				c.CostClass, c.IsFree = "free", &free
			}
			switch {
			case c.SupportedEfforts != nil && len(c.SupportedEfforts) == 0:
				c.Effort = ""
			case len(c.SupportedEfforts) > 0 && !contains(c.SupportedEfforts, "medium"):
				c.Effort = c.SupportedEfforts[0]
			}
			out = append(out, c)
		}
	}
	return out
}

// familyOf guesses a model's maker from its name, for cross-family
// review only; "" when the name doesn't say.
func familyOf(model string) string {
	m := strings.ToLower(model)
	if i := strings.LastIndex(m, "/"); i >= 0 {
		m = m[i+1:]
	}
	switch {
	case strings.HasPrefix(m, "claude"):
		return "anthropic"
	case strings.HasPrefix(m, "gpt"), strings.HasPrefix(m, "o3"), strings.HasPrefix(m, "o4"):
		return "openai"
	case strings.HasPrefix(m, "gemini"):
		return "google"
	case strings.HasPrefix(m, "grok"):
		return "xai"
	}
	return ""
}
