package tui

import (
	"sort"
	"strings"
)

// The Config tab reads like a settings screen: settings in named groups,
// each with a plain name, its value as a switch or a choice, and what it
// does beside (or under) the list. The config file's key is still shown,
// for anyone who edits the file.

// cfgMeta is how the Config tab presents one setting.
type cfgMeta struct {
	group, label, desc string
}

var cfgKnown = map[string]cfgMeta{
	"route.prefer":               {"Routing", "Prefer", "How AFK weighs quality against cost. balanced weighs both, cheap puts free and local models first, best takes the strongest model for the kind of task. --prefer and /prefer win for one run."},
	"route.failover":             {"Routing", "When a run fails", "Where a failed one-shot run goes next: any (the next best route), same-pool (another model on the same CLI and plan) or none (report the failure)."},
	"route.learn":                {"Routing", "Learn from ratings", "Let your ratings of past runs move route scores."},
	"route.pacing":               {"Routing", "Plan pacing", "Lean toward a plan whose quota is about to reset unused, and away from one that will run out first."},
	"route.prefer_free":          {"Routing", "Free first for small work", "Prefer free and local models for low-risk tasks."},
	"route.allow_metered":        {"Routing", "Pay-per-token models", "Allow API models billed per token. Off keeps routing on your plans, gateways and local models."},
	"route.allow_free_reviewers": {"Routing", "Free reviewers", "Let free and local models take reviews."},
	"permissions.default":        {"Permissions", "Default mode", "What a CLI may do without asking: read-only, ask, edits or auto. /mode changes it for one session; yolo is always a deliberate y y on the route card."},
	"trust.repos":                {"Permissions", "Trusted folders", "Folders where yolo may run. Separate them with commas."},
	"gateway":                    {"Gateways", "In use", "The gateway AFK routes gateway models through: the default one, or the only one."},
	"gateway (add)":              {"Gateways", "Add a gateway", "A name and its address, for example: work https://gw.example:4000"},
	"local.engines":              {"Local models", "Find local engines", "auto looks for Ollama, vLLM, llama.cpp, LM Studio and others on this PC; off skips them."},
	"local.gpu":                  {"Local models", "GPU", "The GPU local models run on, as shown on the route card."},
	"harness (off)":              {"Agent CLIs", "Turned off", "CLIs AFK leaves out of routing. Turn them on again from the Harnesses tab."},
	"bench.autosync":             {"Benchmarks", "Daily refresh", "Fetch new benchmark scores in the background when the catalog is a day old."},
}

// cfgInfo is a row's group, name and description, for keys AFK knows and
// for the ones built per gateway or per CLI.
func cfgInfo(key string) cfgMeta {
	if m, ok := cfgKnown[key]; ok {
		return m
	}
	switch {
	case strings.HasPrefix(key, "gateway."):
		parts := strings.SplitN(strings.TrimPrefix(key, "gateway."), ".", 2)
		if len(parts) == 2 {
			descs := map[string]string{
				"url":     "The gateway's base address, such as https://gw.example:4000. A password in it is never shown.",
				"key":     "Where its key is, never the key itself: env:NAME, file:/path, op://vault/item, keychain:NAME or cmd:...",
				"default": "Use this gateway when there is more than one.",
				"kind":    "What it is, for the route card: litellm, openrouter, agentgateway, ...",
				"engine":  "What serves its models, for the route card: vllm, ollama, ...",
				"host":    "Where that engine runs, for the route card.",
			}
			return cfgMeta{"Gateways", parts[0] + " · " + parts[1], descs[parts[1]]}
		}
	case strings.HasPrefix(key, "harness.") && strings.HasSuffix(key, ".vendor_usage"):
		h := strings.TrimSuffix(strings.TrimPrefix(key, "harness."), ".vendor_usage")
		return cfgMeta{"Agent CLIs", h + " usage lookup", "Ask " + h + "'s vendor for your plan usage with the login " + h + " saved here. It asks before it turns on."}
	}
	return cfgMeta{"Other", key, ""}
}

// cfgValue draws a value: switches as ● on / ○ off, choices with ‹ › on
// the selected row.
func (p *Panel) cfgValue(key, val string, e ConfigEdit, editable, selected bool) line {
	t := p.theme
	if !editable {
		return line{sg(t.Dim, "  "+val)}
	}
	if len(e.Choices) == 2 && e.Choices[0] == "on" {
		if val == "on" {
			return line{sg(t.OK, "  ● on")}
		}
		return line{sg(t.Dim, "  ○ off")}
	}
	if len(e.Choices) > 0 && selected {
		return line{sg(t.Accent, "‹ "), sg(t.Plain, val), sg(t.Accent, " ›")}
	}
	if len(e.Choices) > 0 {
		return line{sg(t.Plain, "  "+val)}
	}
	return line{sg(t.Plain, "  "+val)}
}

// configList is the settings, grouped, with the selection bar.
func (p *Panel) configList(w int) []line {
	t := p.theme
	v := p.data.config
	focus := p.cfgKey != "" || p.cfgAskKey != ""
	var out []line
	group := ""
	for i, kv := range v.Rows {
		if focus && i != p.sel[TabConfig] {
			continue
		}
		info := cfgInfo(kv[0])
		if info.group != group && !focus {
			if group != "" {
				out = append(out, nil)
			}
			group = info.group
			out = append(out, line{sg(t.Accent.Bold(true), "  "+group)})
		}
		e, editable := v.Edit[kv[0]]
		sel := i == p.sel[TabConfig]
		val := p.cfgValue(kv[0], kv[1], e, editable, sel)
		if kv[0] == p.cfgKey {
			val = line{sg(t.Plain, p.cfgText), sg(t.Accent, "▏")}
		}
		st := t.Plain
		if !editable {
			st = t.Dim
		}
		row := append(line{sg(st, "  "+col(info.label, 26))}, val...)
		if focus {
			row = append(row, sg(t.Dim, "   "+kv[0])) // its key, for the file
		}
		out = append(out, p.selRow(fitLine(row, w-1), i, w))
	}
	return out
}

// configDetail is what the selected setting does, its key and its values.
func (p *Panel) configDetail(w int) []line {
	t := p.theme
	key, val, e, _ := p.configRow()
	if key == "" {
		return nil
	}
	info := cfgInfo(key)
	out := []line{{sg(t.Bold, info.label)}, {sg(t.Dim, key)}, nil}
	for _, l := range wrap(info.desc, max(w, 20)) {
		out = append(out, line{sg(t.Plain, l)})
	}
	if len(e.Choices) > 0 {
		out = append(out, nil)
		l := line{}
		for i, c := range e.Choices {
			if i > 0 {
				l = append(l, sg(t.Dim, " · "))
			}
			if c == val || strings.HasPrefix(val, c+" ") {
				l = append(l, sg(t.Accent.Bold(true), c))
			} else {
				l = append(l, sg(t.Dim, c))
			}
		}
		out = append(out, l)
	} else if _, editable := p.data.config.Edit[key]; !editable {
		out = append(out, nil, line{sg(t.Dim, "shown only: change it with e (config.toml)")})
	}
	return out
}

// cfgGroups is the order the groups are listed in.
var cfgGroups = []string{"Routing", "Permissions", "Gateways", "Local models", "Agent CLIs", "Benchmarks", "Other"}

// sortConfig puts the rows in group order, keeping their order within a
// group, so each group is listed once.
func sortConfig(v *ConfigView) {
	rank := map[string]int{}
	for i, g := range cfgGroups {
		rank[g] = i
	}
	sort.SliceStable(v.Rows, func(i, j int) bool {
		return rank[cfgInfo(v.Rows[i][0]).group] < rank[cfgInfo(v.Rows[j][0]).group]
	})
}
