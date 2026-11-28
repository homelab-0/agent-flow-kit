package bench

import (
	"strings"
)

// sourceBoard is one extra source as this sync read it.
type sourceBoard struct {
	src  Source
	rows []Row
	live bool
}

// weight is a source's weight for a task kind: config's
// bench.weights.<kind>.<source>, else the source's own weight (0 leaves
// it out).
func (s *syncer) weight(kind, src string, def float64) float64 {
	if w, ok := s.weights[kind][src]; ok {
		return w
	}
	return def
}

// fresh is whether a part synced at epoch ep is still inside the carry
// window (and not from the future).
func (s *syncer) fresh(ep int64) bool {
	return s.carry > 0 && s.now-ep <= s.carry && ep <= s.now+60
}

// blend mixes each extra source's score into the candidate's benchmarks.
//
// For each kind of task, the parts are the LMArena score (when it was
// measured, not estimated) and the score of every enabled source that
// counts for that kind and lists the model. The blended score is their
// weighted average. An estimate is never averaged with a measurement: a
// measured part replaces it. A source that doesn't list the model adds
// nothing; most boards lag new models, so leaving a model out says nothing
// about it. Each part is kept on the entry, so a route can show how its
// score was made.
//
// est is the catalog's estimate for a kind, the fallback when nothing
// measured with a weight above 0 is left.
func (s *syncer) blend(c map[string]any, bm, pcb map[string]any, est func(string) map[string]any) {
	names := candidateNames(c)
	match := str(c["arena_match"])
	for _, kind := range TaskKinds {
		cur, _ := bm[kind].(map[string]any)
		wasBlend := cur != nil && str(cur["feed"]) == "blend"
		var parts []any
		var sum, wsum float64
		add := func(p map[string]any, score, w float64) {
			p["score"], p["weight"] = score, w
			parts = append(parts, p)
			if w > 0 {
				sum += score * w
				wsum += w
			}
		}
		arena := s.arenaPart(cur, kind, match)
		if arena != nil {
			sc, _ := number(arena["score"])
			add(arena, sc, s.weight(kind, "lmarena", 1))
		}
		extra := 0
		for _, sb := range s.sources {
			if !counts(sb.src, kind) {
				continue
			}
			w := s.weight(kind, sb.src.ID, sb.src.Weight)
			if sb.live {
				hit := MatchBoard(sb.rows, names...)
				if hit == nil {
					continue
				}
				part := map[string]any{
					"source": sb.src.ID, "name": sb.src.Name, "rank": hit.Rank, "value": hit.Value, "listed": len(sb.rows),
					"model": hit.Name, "synced_at": s.ts, "synced_epoch": s.now,
					"label": sb.src.Name + " #" + numText(hit.Rank) + " (" + numText(hit.Value) + ")",
				}
				add(part, RankScore(97.5, hit.Rank), w)
			} else if p := s.carriedPart(pcb, kind, sb.src.ID, names); p != nil {
				sc, _ := number(p["score"])
				add(p, sc, w)
			} else {
				continue
			}
			extra++
		}
		switch {
		case extra > 0 && wsum > 0:
			var labels []string
			for _, p := range parts {
				pm := p.(map[string]any)
				if w, _ := number(pm["weight"]); w > 0 {
					labels = append(labels, str(pm["label"]))
				}
			}
			e := map[string]any{
				"score": r1(sum / wsum), "benchmark": strings.Join(labels, " + "), "live": true, "basis": "measured",
				"feed": "blend", "parts": parts, "synced_at": s.ts, "synced_epoch": s.now, "match": match,
			}
			if arena != nil {
				// The reasoning half of architecture keeps its own clock.
				e["text_score"], e["text_synced_epoch"] = arena["text_score"], arena["text_synced_epoch"]
			}
			bm[kind] = e
		case arena != nil && wsum > 0:
			// No other source scores it now: LMArena alone, as it was.
			if wasBlend {
				bm[kind] = arenaEntry(arena)
			}
		case wasBlend || (arena != nil && wsum == 0):
			// Nothing measured with a weight above 0 is left: the
			// catalog's estimate, never last sync's composite.
			if e := est(kind); e != nil {
				bm[kind] = e
			} else {
				delete(bm, kind)
			}
		}
	}
}

// arenaPart is the LMArena measurement an entry rests on, as a part: the
// entry itself when LMArena set it, or the LMArena part of last sync's
// blend while that part is inside its own carry window and for the same
// model. nil when there is none.
func (s *syncer) arenaPart(cur map[string]any, kind, match string) map[string]any {
	if cur == nil || cur["live"] != true || str(cur["basis"]) != "measured" {
		return nil
	}
	base := cur
	if str(cur["feed"]) == "blend" {
		base = nil
		for _, p := range anyList(cur["parts"]) {
			if pm, ok := p.(map[string]any); ok && str(pm["source"]) == "lmarena" {
				base = pm
			}
		}
		if base == nil || !s.fresh(int64OrZero(base["synced_epoch"])) || orEmpty(base["match"]) != match {
			return nil
		}
	}
	label := str(base["benchmark"])
	if label == "" {
		label = str(base["label"])
	}
	p := map[string]any{"source": "lmarena", "name": "LMArena", "label": label,
		"feed": base["feed"], "rank": base["rank"], "value": base["value"], "match": match,
		"synced_at": base["synced_at"], "synced_epoch": base["synced_epoch"], "score": base["score"]}
	if kind == "architecture" {
		p["text_score"], p["text_synced_epoch"] = base["text_score"], base["text_synced_epoch"]
		// The reasoning half has run out: the agent rank alone.
		if base["text_score"] != nil && !s.fresh(int64OrZero(base["text_synced_epoch"])) && base["rank"] != nil {
			rank, _ := number(base["rank"])
			p["score"] = RankScore(98.0, rank)
			p["text_score"], p["text_synced_epoch"] = nil, nil
			p["label"] = "LMArena Agent #" + numText(base["rank"])
		}
	}
	return p
}

// arenaEntry turns an LMArena part back into a benchmark entry.
func arenaEntry(p map[string]any) map[string]any {
	e := clone(p)
	for _, k := range []string{"weight", "name", "source", "label"} {
		delete(e, k)
	}
	e["benchmark"], e["live"], e["basis"] = p["label"], true, "measured"
	return e
}

// carriedPart is the part an earlier sync read from a source that is
// down now, while it is inside the carry window and still for this model.
func (s *syncer) carriedPart(pcb map[string]any, kind, src string, names []string) map[string]any {
	if pcb == nil {
		return nil
	}
	e, _ := pcb[kind].(map[string]any)
	for _, p := range anyList(e["parts"]) {
		pm, ok := p.(map[string]any)
		if !ok || str(pm["source"]) != src {
			continue
		}
		if !s.fresh(int64OrZero(pm["synced_epoch"])) || MatchBoard([]Row{{Name: str(pm["model"])}}, names...) == nil {
			return nil
		}
		out := clone(pm)
		out["carried"] = true
		return out
	}
	return nil
}

func counts(s Source, kind string) bool {
	for _, k := range s.Tasks {
		if k == kind {
			return true
		}
	}
	return false
}

func anyList(v any) []any {
	l, _ := v.([]any)
	return l
}

// sourceStatus is a source's line in the receipt.
func sourceStatus(sb sourceBoard, err error, matched int) string {
	if err != nil {
		return "unavailable: " + err.Error()
	}
	return "live_synced (" + itoa(len(sb.rows)) + " models, " + itoa(matched) + " matched)"
}

func itoa(n int) string { return numText(float64(n)) }

// matchedCount is how many catalog models a source's board lists.
func matchedCount(base map[string]any, sb sourceBoard) int {
	if !sb.live {
		return 0
	}
	n := 0
	for _, c := range anyList(base["candidates"]) {
		if cm, ok := c.(map[string]any); ok && MatchBoard(sb.rows, candidateNames(cm)...) != nil {
			n++
		}
	}
	return n
}
