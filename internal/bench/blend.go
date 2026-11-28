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
// bench.weights.<kind>.<source>, else the source's own weight, else 1.
func (s *syncer) weight(kind, src string, def float64) float64 {
	if w, ok := s.weights[kind][src]; ok {
		return w
	}
	if def > 0 {
		return def
	}
	return 1
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
func (s *syncer) blend(c map[string]any, bm, pcb map[string]any) {
	if len(s.sources) == 0 {
		return
	}
	names := candidateNames(c)
	for _, kind := range TaskKinds {
		cur, _ := bm[kind].(map[string]any)
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
		// The LMArena part, when the entry rests on a measurement.
		var arena map[string]any
		if cur != nil && cur["live"] == true && str(cur["basis"]) == "measured" {
			base := cur
			// A blend from an earlier sync keeps its LMArena part only.
			if str(cur["feed"]) == "blend" {
				base = nil
				for _, p := range anyList(cur["parts"]) {
					if pm, ok := p.(map[string]any); ok && str(pm["source"]) == "lmarena" {
						base = pm
					}
				}
			}
			if base != nil {
				label := str(base["benchmark"])
				if label == "" {
					label = str(base["label"])
				}
				arena = map[string]any{"source": "lmarena", "name": "LMArena", "label": label,
					"feed": base["feed"], "rank": base["rank"], "value": base["value"],
					"synced_at": base["synced_at"], "synced_epoch": base["synced_epoch"]}
				sc, _ := number(base["score"])
				add(arena, sc, s.weight(kind, "lmarena", 1))
			}
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
			} else if p := s.carriedPart(pcb, kind, sb.src.ID); p != nil {
				sc, _ := number(p["score"])
				add(p, sc, w)
			} else {
				continue
			}
			extra++
		}
		if extra == 0 {
			if arena != nil && str(cur["feed"]) == "blend" {
				// Last sync's blend, with no source listing the model now:
				// back to the LMArena part alone.
				e := clone(arena)
				delete(e, "weight")
				delete(e, "name")
				delete(e, "source")
				e["benchmark"], e["live"], e["basis"] = arena["label"], true, "measured"
				delete(e, "label")
				bm[kind] = e
			}
			continue
		}
		if wsum == 0 {
			// Every part weighted 0: the entry stays as it was, but says
			// what was read.
			if cur != nil {
				cur = clone(cur)
				cur["parts"] = parts
				bm[kind] = cur
			}
			continue
		}
		var labels []string
		for _, p := range parts {
			pm := p.(map[string]any)
			if w, _ := number(pm["weight"]); w > 0 {
				labels = append(labels, str(pm["label"]))
			}
		}
		e := map[string]any{
			"score": r1(sum / wsum), "benchmark": strings.Join(labels, " + "), "live": true, "basis": "measured",
			"feed": "blend", "parts": parts, "synced_at": s.ts, "synced_epoch": s.now,
		}
		if len(labels) == 1 {
			e["benchmark"] = labels[0]
		}
		bm[kind] = e
	}
}

// carriedPart is the part an earlier sync read from a source that is
// down now, while it is inside the carry window.
func (s *syncer) carriedPart(pcb map[string]any, kind, src string) map[string]any {
	if s.carry <= 0 || pcb == nil {
		return nil
	}
	e, _ := pcb[kind].(map[string]any)
	for _, p := range anyList(e["parts"]) {
		pm, ok := p.(map[string]any)
		if !ok || str(pm["source"]) != src {
			continue
		}
		ep := int64OrZero(pm["synced_epoch"])
		if s.now-ep > s.carry || ep > s.now+60 {
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
