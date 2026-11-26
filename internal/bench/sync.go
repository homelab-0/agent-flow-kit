// Package bench refreshes the benchmark catalog from public leaderboards
// (afk bench sync). It replaced the bash engine's benchmark sync and
// writes the same catalog format.
//
// Scores that can be measured come from the LMArena leaderboards (agent,
// webdev, text); context windows come from models.dev. Every other score is
// the fixed estimate in the built-in catalog. Each measured entry is marked
// `live: true` with its rank, raw value and sync time, so a route can say
// whether it rests on a measurement or an estimate.
//
// No feed is sent a credential of any kind: every request is a plain GET
// with no headers of AFK's own, and nothing is read from the environment
// to authenticate with.
package bench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/statefile"
)

// Schemas.
const (
	SchemaReceipt = "afk-benchmark-sync/3"
	SchemaCatalog = "afk-benchmark-catalog/3"
)

// DefaultCarry is how long a measured score is kept while its board is
// unreachable (14 days).
const DefaultCarry = 14 * 24 * time.Hour

// Feed names, as AFK_BENCHMARK_FEED_DIR names the fixture files.
const (
	FeedAgent     = "lmarena-agent"
	FeedWebdev    = "lmarena-webdev"
	FeedText      = "lmarena-text"
	FeedModelsDev = "models-dev"
)

const lmarenaURL = "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&split=latest&offset=0&length=100&config="

// FeedURLs are where the feeds are read from.
var FeedURLs = map[string]string{
	FeedAgent:     lmarenaURL + "agent",
	FeedWebdev:    lmarenaURL + "webdev",
	FeedText:      lmarenaURL + "text",
	FeedModelsDev: "https://models.dev/api.json",
}

// Fetcher reads one feed.
type Fetcher interface {
	Fetch(ctx context.Context, name string) ([]byte, error)
}

// maxFeed is the most of one feed that is read.
const maxFeed = 32 << 20

// HTTPFetcher reads the feeds from the public endpoints.
type HTTPFetcher struct{ Client *http.Client }

// Fetch is a plain GET with an 8-second limit.
func (h HTTPFetcher) Fetch(ctx context.Context, name string) ([]byte, error) {
	u, ok := FeedURLs[name]
	if !ok {
		return nil, fmt.Errorf("unknown feed %s", name)
	}
	cl := h.Client
	if cl == nil {
		cl = &http.Client{Timeout: 8 * time.Second}
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", name, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxFeed))
}

// DirFetcher reads <dir>/<name>.json (AFK_BENCHMARK_FEED_DIR, for tests and
// offline use).
type DirFetcher struct{ Dir string }

// Fetch reads the fixture file.
func (d DirFetcher) Fetch(_ context.Context, name string) ([]byte, error) {
	return os.ReadFile(filepath.Join(d.Dir, name+".json"))
}

// Options is one sync.
type Options struct {
	// Base is the catalog the estimates and candidates come from.
	Base []byte
	// Out is the catalog to write; the previous one there supplies the
	// scores to carry while a feed is down.
	Out string
	Now time.Time
	// Carry is how long a measured score is kept while its board is down;
	// 0 keeps none (callers pass DefaultCarry for the usual 14 days).
	Carry time.Duration
	Feeds Fetcher
}

// Feeds is the state of each feed in a receipt.
type Feeds struct {
	Agent              string `json:"lmarena_agent"`
	Webdev             string `json:"lmarena_webdev"`
	Text               string `json:"lmarena_text"`
	SWEBench           string `json:"swe_bench_official"`
	ModelsDev          string `json:"models_dev"`
	ArtificialAnalysis string `json:"artificial_analysis"`
}

// Receipt is what a sync reports (afk-benchmark-sync/3).
type Receipt struct {
	Schema          string    `json:"schema"`
	Result          string    `json:"result"` // synced, feeds_unavailable or error
	Reason          string    `json:"reason,omitempty"`
	CatalogPath     string    `json:"catalog_path"`
	SyncedAt        string    `json:"synced_at,omitempty"`
	CandidatesCount *int      `json:"candidates_count,omitempty"`
	LiveScores      *int      `json:"live_scores,omitempty"`
	Unmatched       *[]string `json:"unmatched,omitempty"`
	Feeds           *Feeds    `json:"feeds,omitempty"`
}

// Exit statuses, as the bash sync returns them.
const (
	ExitSynced      = 0
	ExitError       = 1
	ExitUnavailable = 3
)

// Row is one leaderboard row, reduced.
type Row struct {
	Name  string
	Rank  float64
	Value any
	Date  any
}

// ParseBoard reads a leaderboard in the shape the dataset server returns:
// {"rows":[{"row":{"model_name","rank","score"|"rating","category",
// "leaderboard_publish_date"}}]}. Rows without a numeric rank, and rows of
// a category other than "overall", are dropped. ok is false when the
// document is not JSON or lists no usable row: the board counts as
// unreachable.
func ParseBoard(b []byte) ([]Row, bool) {
	var doc struct {
		Rows []struct {
			Row map[string]any `json:"row"`
		} `json:"rows"`
	}
	if json.Unmarshal(b, &doc) != nil {
		return nil, false
	}
	var rows []Row
	for _, r := range doc.Rows {
		m := r.Row
		if m == nil {
			continue
		}
		rank, ok := m["rank"].(float64)
		if !ok {
			continue
		}
		cat := "overall"
		if c, ok := m["category"].(string); ok {
			cat = c
		} else if m["category"] != nil {
			continue
		}
		if strings.ToLower(cat) != "overall" {
			continue
		}
		name, _ := m["model_name"].(string)
		var value any
		if v, ok := m["score"]; ok && v != nil && v != false {
			value = v
		} else if v, ok := m["rating"]; ok && v != false {
			value = v
		}
		var date any
		if d, ok := m["leaderboard_publish_date"]; ok && d != false {
			date = d
		}
		rows = append(rows, Row{Name: name, Rank: rank, Value: value, Date: date})
	}
	return rows, len(rows) > 0
}

// ParseModelsDev reads models.dev's api.json into provider → model →
// context window (nil when it gives none).
func ParseModelsDev(b []byte) (map[string]map[string]any, bool) {
	var doc map[string]json.RawMessage
	if json.Unmarshal(b, &doc) != nil || doc == nil {
		return nil, false
	}
	out := map[string]map[string]any{}
	for prov, raw := range doc {
		var p struct {
			Models map[string]struct {
				Limit struct {
					Context any `json:"context"`
				} `json:"limit"`
			} `json:"models"`
		}
		models := map[string]any{}
		if json.Unmarshal(raw, &p) == nil {
			for id, m := range p.Models {
				if m.Limit.Context != false {
					models[id] = m.Limit.Context
				}
			}
		}
		out[prov] = models
	}
	return out, true
}

var (
	effortSuffix = regexp.MustCompile(`\s*\((low|medium|high|xhigh|max|thinking)(,[^)]*)?\)\s*$`)
	nonWord      = regexp.MustCompile(`[^a-z0-9.]+`)
)

// Norm is a leaderboard name compared whole: lower case, without an effort
// suffix ("(Max)", "(xHigh)", "(High, thinking)"), punctuation as spaces. A
// dated or harness-specific variant stays a separate model.
func Norm(s string) string {
	s = strings.ToLower(s)
	s = effortSuffix.ReplaceAllString(s, "")
	s = nonWord.ReplaceAllString(s, " ")
	return strings.Trim(s, " ")
}

// Best is the best-ranked row whose name matches name whole, or nil. A
// partial name never matches, so "Grok 4.5" cannot take the score of
// "Grok 4.7".
func Best(rows []Row, name string) *Row {
	want := Norm(name)
	if want == "" {
		return nil
	}
	var hits []Row
	for _, r := range rows {
		if Norm(r.Name) == want {
			hits = append(hits, r)
		}
	}
	if len(hits) == 0 {
		return nil
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].Rank < hits[j].Rank })
	return &hits[0]
}

// RankScore turns a board rank into a score: top for #1, 0.9 less per
// rank, never below 80, to one decimal.
func RankScore(top, rank float64) float64 {
	v := top - (rank-1)*0.9
	if v < 80 {
		return 80
	}
	return r1(v)
}

func r1(v float64) float64 { return math.Round(v*10) / 10 }

// numText is a number as jq's tostring writes it.
func numText(v any) string {
	switch n := v.(type) {
	case float64:
		return strconv.FormatFloat(n, 'f', -1, 64)
	case json.Number:
		return n.String()
	case string:
		return n
	case nil:
		return "null"
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// Sync refreshes the catalog. When no leaderboard is reachable, an
// existing catalog is left exactly as it is (rewriting it would replace the
// last measured scores with estimates and make it look fresh for a day).
func Sync(ctx context.Context, o Options) (Receipt, int) {
	if o.Now.IsZero() {
		o.Now = time.Now()
	}
	ts := o.Now.UTC().Format("2006-01-02T15:04:05Z")
	base, err := decodeObject(o.Base)
	if err != nil || !isArray(base["candidates"]) {
		return Receipt{Schema: SchemaReceipt, Result: "error", Reason: "the built-in catalog is missing or unreadable", CatalogPath: o.Out}, ExitError
	}

	feeds := Feeds{Agent: "offline", Webdev: "offline", Text: "offline", SWEBench: "not_scored", ModelsDev: "offline",
		// Artificial Analysis needs an API key, and AFK never handles one.
		ArtificialAnalysis: "not_used"}
	boards := map[string][]Row{}
	for _, f := range []struct {
		name  string
		state *string
	}{{FeedAgent, &feeds.Agent}, {FeedWebdev, &feeds.Webdev}, {FeedText, &feeds.Text}} {
		b, err := o.Feeds.Fetch(ctx, f.name)
		if err != nil {
			continue
		}
		rows, ok := ParseBoard(b)
		if !ok {
			continue
		}
		boards[f.name] = rows
		date := "latest"
		if rows[0].Date != nil {
			date = numText(rows[0].Date)
		}
		*f.state = "live_synced (" + date + ")"
	}
	var mdev map[string]map[string]any
	mdLive := false
	if b, err := o.Feeds.Fetch(ctx, FeedModelsDev); err == nil {
		if m, ok := ParseModelsDev(b); ok {
			mdev, mdLive = m, true
			feeds.ModelsDev = "live_synced"
		}
	}

	var prev map[string]any
	if b, err := os.ReadFile(o.Out); err == nil {
		if p, err := decodeObject(b); err == nil && p["schema"] == SchemaCatalog && isArray(p["candidates"]) {
			prev = p
		}
	}
	anyBoard := len(boards) > 0
	result, rc := "synced", ExitSynced
	if !anyBoard {
		result, rc = "feeds_unavailable", ExitUnavailable
	}
	if anyBoard || prev == nil {
		s := &syncer{
			now: o.Now.Unix(), ts: ts, carry: int64(o.Carry / time.Second),
			ag: boards[FeedAgent], wd: boards[FeedWebdev], tx: boards[FeedText],
			agLive: boards[FeedAgent] != nil, wdLive: boards[FeedWebdev] != nil, txLive: boards[FeedText] != nil,
			md: mdev, mdLive: mdLive, prev: prevByID(prev),
		}
		doc := s.catalog(base, feeds)
		b, err := json.MarshalIndent(doc, "", "  ")
		if err == nil {
			err = statefile.WriteJSON(o.Out, append(b, '\n'))
		}
		if err != nil {
			return Receipt{Schema: SchemaReceipt, Result: "error", CatalogPath: o.Out, SyncedAt: ts,
				Reason: "the refreshed catalog could not be built or written; the previous catalog is unchanged"}, ExitError
		}
	}

	rec := Receipt{Schema: SchemaReceipt, Result: result, CatalogPath: o.Out, SyncedAt: ts, Feeds: &feeds}
	unmatched := []string{}
	count, live := 0, 0
	if b, err := os.ReadFile(o.Out); err == nil {
		if doc, err := decodeObject(b); err == nil {
			cands, _ := doc["candidates"].([]any)
			count = len(cands)
			live = countScores(cands, func(e map[string]any) bool { return e["live"] == true })
			if sr, ok := doc["sync_receipt"].(map[string]any); ok {
				if um, ok := sr["unmatched"].([]any); ok {
					for _, u := range um {
						if s, ok := u.(string); ok {
							unmatched = append(unmatched, s)
						}
					}
				}
			}
		}
	}
	rec.CandidatesCount, rec.LiveScores, rec.Unmatched = &count, &live, &unmatched
	return rec, rc
}

func decodeObject(b []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	if m == nil {
		return nil, errors.New("not an object")
	}
	return m, nil
}

func isArray(v any) bool { _, ok := v.([]any); return ok }

func prevByID(prev map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	cands, _ := prev["candidates"].([]any)
	for _, c := range cands {
		if m, ok := c.(map[string]any); ok {
			if id, ok := m["id"].(string); ok {
				if _, seen := out[id]; !seen {
					out[id] = m
				}
			}
		}
	}
	return out
}

func countScores(cands []any, pred func(map[string]any) bool) int {
	n := 0
	for _, c := range cands {
		m, _ := c.(map[string]any)
		bm, _ := m["benchmarks"].(map[string]any)
		for _, e := range bm {
			if em, ok := e.(map[string]any); ok && pred(em) {
				n++
			}
		}
	}
	return n
}
