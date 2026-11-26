package bench

import (
	"encoding/json"
	"math"
)

// syncer builds one refreshed catalog.
type syncer struct {
	now, carry             int64
	ts                     string
	ag, wd, tx             []Row
	agLive, wdLive, txLive bool
	md                     map[string]map[string]any
	mdLive                 bool
	prev                   map[string]map[string]any
}

// catalog is the base catalog with every candidate rescored and a
// sync_receipt.
func (s *syncer) catalog(base map[string]any, feeds Feeds) map[string]any {
	doc := clone(base)
	doc["updated_at"] = s.ts
	cands, _ := base["candidates"].([]any)
	out := make([]any, 0, len(cands))
	var unmatched []any
	for _, c := range cands {
		cm, ok := c.(map[string]any)
		if !ok {
			out = append(out, c)
			continue
		}
		nc := s.candidate(cm)
		out = append(out, nc)
		if s.agLive && str(cm["specialist_domain"]) == "" && !truthy(cm["frontier_only"]) {
			bm, _ := nc["benchmarks"].(map[string]any)
			cc, _ := bm["coding_complex"].(map[string]any)
			if cc == nil || cc["live"] != true {
				unmatched = append(unmatched, cm["id"])
			}
		}
	}
	doc["candidates"] = out
	if unmatched == nil {
		unmatched = []any{}
	}
	doc["sync_receipt"] = map[string]any{
		"synced_at":           s.ts,
		"lmarena_agent":       feeds.Agent,
		"lmarena_webdev":      feeds.Webdev,
		"lmarena_text":        feeds.Text,
		"swe_bench_official":  "not_scored",
		"swe_bench_entries":   0,
		"models_dev":          feeds.ModelsDev,
		"artificial_analysis": feeds.ArtificialAnalysis,
		"live_scores":         countScores(out, func(e map[string]any) bool { return e["live"] == true }),
		"estimated_scores":    countScores(out, func(e map[string]any) bool { return e["live"] != true }),
		"capped_scores":       countScores(out, func(e map[string]any) bool { return e["basis"] == "capped" }),
		// A general candidate a reachable agent board does not list by
		// that name: either it is not ranked or its arena_match is wrong.
		"unmatched": unmatched,
	}
	return doc
}

// candidate rescores one candidate.
func (s *syncer) candidate(c map[string]any) map[string]any {
	out := clone(c)
	base, _ := c["benchmarks"].(map[string]any)
	bm := clone(base)
	pc := s.prev[str(c["id"])]
	pcb, _ := pc["benchmarks"].(map[string]any)
	match := str(c["arena_match"])
	general := str(c["specialist_domain"]) == ""
	agentOK := general && !truthy(c["frontier_only"])

	// The context window: models.dev, else (only for a model models.dev
	// does not describe this time) the last sync's figure, else the
	// catalog's own. A window an earlier catalog had for a different model
	// must not come back.
	var window any
	if p, ok := s.md[str(c["models_dev_provider"])]; ok {
		window = p[str(c["models_dev_id"])]
	}
	if !truthy(window) && !(s.mdLive || str(c["models_dev_id"]) == "") && pc != nil {
		window = pc["window_tokens"]
	}
	if !truthy(window) {
		window = c["window_tokens"]
	}
	out["window_tokens"] = window

	entry := func(m map[string]any, k string) map[string]any {
		e, _ := m[k].(map[string]any)
		return e
	}
	measured := func(feed string, hit *Row, score float64, label string) map[string]any {
		return map[string]any{
			"score": score, "benchmark": label, "live": true, "basis": "measured", "feed": feed,
			"rank": hit.Rank, "value": hit.Value, "match": match, "synced_at": s.ts, "synced_epoch": s.now,
		}
	}
	// A score an earlier sync read off a reachable board, for the same
	// leaderboard name, still inside the carry window. A candidate whose
	// name changed (a model upgrade under the same id) does not inherit
	// the score of the model it replaced.
	carried := func(e map[string]any) map[string]any {
		if e == nil {
			return nil
		}
		basis := "estimate"
		if truthy(e["basis"]) {
			basis = str(e["basis"])
		}
		if basis == "estimate" {
			return nil
		}
		if m, has := e["match"]; has && orEmpty(m) != match {
			return nil
		}
		ep := int64OrZero(e["synced_epoch"])
		if s.now-ep > s.carry || ep > s.now+60 {
			return nil
		}
		out := clone(e)
		if !truthy(e["match"]) {
			out["match"] = match
		}
		return out
	}
	estimate := func(e map[string]any) map[string]any {
		if e == nil {
			return nil
		}
		out := clone(e)
		for _, k := range []string{"feed", "rank", "value", "match", "synced_at", "synced_epoch", "text_score", "text_synced_epoch"} {
			delete(out, k)
		}
		out["live"], out["basis"] = false, "estimate"
		return out
	}
	// A model a reachable board does not list ranks below every model it
	// does list: its estimate is held to the score of the rank after the
	// last one, so an unranked model cannot outscore a ranked one on a
	// guess.
	unlisted := func(e map[string]any, feed string, top float64, rows []Row, board string) map[string]any {
		if e == nil {
			return nil
		}
		last := 0.0
		for _, r := range rows {
			if r.Rank > last {
				last = r.Rank
			}
		}
		limit := RankScore(top, last+1)
		if score, _ := number(e["score"]); score > limit {
			out := clone(e)
			for _, k := range []string{"rank", "value", "text_score", "text_synced_epoch"} {
				delete(out, k)
			}
			name := "Estimate"
			if truthy(e["benchmark"]) {
				name = str(e["benchmark"])
			}
			out["score"], out["live"], out["basis"], out["feed"], out["match"] = limit, false, "capped", feed, match
			out["benchmark"] = name + " (not listed on " + board + ")"
			out["synced_at"], out["synced_epoch"] = s.ts, s.now
			return out
		}
		return estimate(e)
	}
	or := func(a, b map[string]any) map[string]any {
		if a != nil {
			return a
		}
		return b
	}
	set := func(k string, v map[string]any) {
		if v == nil {
			delete(bm, k)
			return
		}
		bm[k] = v
	}

	agHit, wdHit, txHit := Best(s.ag, match), Best(s.wd, match), Best(s.tx, match)

	if agentOK {
		switch {
		case s.agLive && agHit != nil:
			agScore := RankScore(98.0, agHit.Rank)
			rank := numText(agHit.Rank)
			date := "live"
			if agHit.Date != nil {
				date = numText(agHit.Date)
			}
			set("coding_complex", measured("lmarena_agent", agHit, agScore, "LMArena Agent #"+rank+" ("+date+")"))
			// A review is what an unattended merge rests on, so the
			// reviewer is chosen on the same measured agent ranking as
			// complex builds, not on a hand-written estimate.
			set("coding_review", measured("lmarena_agent", agHit, agScore, "LMArena Agent #"+rank+" (review)"))
			// The reasoning half comes from the text board: this sync,
			// else the value an earlier sync measured, by the time of that
			// measurement.
			parch := carried(entry(pcb, "architecture"))
			var txs, txsEp any
			switch {
			case s.txLive:
				if txHit != nil {
					txs = RankScore(97.5, txHit.Rank)
				}
				txsEp = s.now
			case parch != nil && parch["text_score"] != nil && s.now-int64OrZero(parch["text_synced_epoch"]) <= s.carry:
				txs, txsEp = parch["text_score"], parch["text_synced_epoch"]
			}
			half := agScore
			label := "LMArena Agent #" + rank
			if txs != nil {
				half, _ = number(txs)
				label += " + Reasoning"
			}
			arch := measured("lmarena_agent", agHit, r1(agScore*0.6+half*0.4), label)
			arch["text_score"], arch["text_synced_epoch"] = txs, txsEp
			set("architecture", arch)
		case s.agLive:
			for _, k := range []string{"coding_complex", "coding_review", "architecture"} {
				set(k, unlisted(entry(base, k), "lmarena_agent", 98.0, s.ag, "LMArena Agent"))
			}
		default:
			set("coding_complex", or(carried(entry(pcb, "coding_complex")), estimate(entry(base, "coding_complex"))))
			set("coding_review", or(carried(entry(pcb, "coding_review")), estimate(entry(base, "coding_review"))))
			// Carried whole only while its reasoning half is still in its
			// own window; otherwise it falls back to the agent half alone.
			ca := carried(entry(pcb, "architecture"))
			switch {
			case ca == nil:
				ca = estimate(entry(base, "architecture"))
			case ca["text_score"] != nil && s.now-int64OrZero(ca["text_synced_epoch"]) > s.carry && ca["rank"] != nil:
				rank, _ := number(ca["rank"])
				ca["score"] = RankScore(98.0, rank)
				ca["text_score"], ca["text_synced_epoch"] = nil, nil
				ca["benchmark"] = "LMArena Agent #" + numText(ca["rank"])
			}
			set("architecture", ca)
		}
	}

	if general {
		elo := func(h *Row) string {
			if v, ok := h.Value.(float64); ok {
				return " (" + numText(math.Round(v)) + " Elo)"
			}
			return ""
		}
		board := func(k, feed string, live bool, hit *Row, rows []Row, label, boardName string) {
			switch {
			case live && hit != nil:
				set(k, measured(feed, hit, RankScore(97.5, hit.Rank), label+" #"+numText(hit.Rank)+elo(hit)))
			case live:
				set(k, unlisted(entry(base, k), feed, 97.5, rows, boardName))
			default:
				set(k, or(carried(entry(pcb, k)), estimate(entry(base, k))))
			}
		}
		board("webdev", "lmarena_webdev", s.wdLive, wdHit, s.wd, "LMArena WebDev", "LMArena WebDev")
		board("research", "lmarena_text", s.txLive, txHit, s.tx, "LMArena Reasoning", "LMArena Reasoning")
	}
	for k, v := range bm {
		if v == nil {
			delete(bm, k)
		}
	}
	out["benchmarks"] = bm
	return out
}

func clone(m map[string]any) map[string]any {
	out := make(map[string]any, len(m)+4)
	for k, v := range m {
		out[k] = v
	}
	return out
}

func truthy(v any) bool { return v != nil && v != false }

func str(v any) string {
	s, _ := v.(string)
	return s
}

// orEmpty is a value compared as jq's (x // "") would be.
func orEmpty(v any) string {
	if !truthy(v) {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return numText(v)
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int64:
		return float64(n), true
	case int:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}

func int64OrZero(v any) int64 {
	f, ok := number(v)
	if !ok {
		return 0
	}
	return int64(f)
}
