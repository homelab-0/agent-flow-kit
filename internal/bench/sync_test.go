package bench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
)

// The fixtures in testdata/feeds are leaderboards in the shape the dataset
// server returns: named rows for the catalog's models, padded to 45 ranks
// with filler rows, so a model the board does not list sits below rank 45.
// The agent board also has one row whose rank is not a number.
const feedDir = "testdata/feeds"

var t0 = time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)

// mapFeeds serves fixture documents by name; a missing name is offline.
type mapFeeds map[string][]byte

func (m mapFeeds) Fetch(_ context.Context, name string) ([]byte, error) {
	if b, ok := m[name]; ok {
		return b, nil
	}
	return nil, os.ErrNotExist
}

func fixtures(t *testing.T, names ...string) mapFeeds {
	t.Helper()
	m := mapFeeds{}
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(feedDir, n+".json"))
		if err != nil {
			t.Fatal(err)
		}
		m[n] = b
	}
	return m
}

var allFeeds = []string{FeedAgent, FeedWebdev, FeedText, FeedModelsDev}

func sync(t *testing.T, out string, feeds Fetcher, now time.Time, carry time.Duration) (Receipt, int) {
	t.Helper()
	if carry == 0 {
		carry = DefaultCarry
	}
	return Sync(context.Background(), Options{Base: router.DefaultCatalogJSON(), Out: out, Now: now, Carry: carry, Feeds: feeds})
}

type catalog struct {
	Schema     string `json:"schema"`
	Candidates []struct {
		ID           string                    `json:"id"`
		WindowTokens *float64                  `json:"window_tokens"`
		Benchmarks   map[string]map[string]any `json:"benchmarks"`
	} `json:"candidates"`
	Receipt map[string]any `json:"sync_receipt"`
}

func read(t *testing.T, path string) catalog {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var c catalog
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func (c catalog) entry(t *testing.T, id, class string) map[string]any {
	t.Helper()
	for _, cand := range c.Candidates {
		if cand.ID == id {
			return cand.Benchmarks[class]
		}
	}
	t.Fatalf("no candidate %s", id)
	return nil
}

func (c catalog) window(t *testing.T, id string) float64 {
	t.Helper()
	for _, cand := range c.Candidates {
		if cand.ID == id && cand.WindowTokens != nil {
			return *cand.WindowTokens
		}
	}
	return -1
}

func baseScore(t *testing.T, id, class string) any {
	t.Helper()
	var c catalog
	if err := json.Unmarshal(router.DefaultCatalogJSON(), &c); err != nil {
		t.Fatal(err)
	}
	return c.entry(t, id, class)["score"]
}

func want(t *testing.T, what string, got, wantV any) {
	t.Helper()
	if !reflect.DeepEqual(got, wantV) {
		t.Errorf("%s: got %v (%T), want %v (%T)", what, got, got, wantV, wantV)
	}
}

func TestSyncMeasuresScoresFromTheBoards(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	rec, rc := sync(t, out, fixtures(t, allFeeds...), t0, 0)
	want(t, "exit", rc, ExitSynced)
	want(t, "result", rec.Result, "synced")
	c := read(t, out)
	want(t, "schema", c.Schema, SchemaCatalog)

	opus := c.entry(t, "claude-opus-native", "coding_complex")
	// Opus 5.5 is #2 (Max) and #9 (High): the best-ranked row wins.
	want(t, "opus score", opus["score"], 97.1)
	want(t, "opus rank", opus["rank"], 2.0)
	want(t, "opus basis", opus["basis"], "measured")
	want(t, "opus live", opus["live"], true)
	want(t, "opus label", opus["benchmark"], "LMArena Agent #2 (2026-11-11)")

	grok := c.entry(t, "grok-4.7-native", "coding_complex")
	want(t, "grok 4.7 from rank 17", grok["score"], 83.6)

	// Grok 4.5 is not on the board: it does not borrow Grok 4.7's row, and
	// its estimate is capped below the last rank.
	g45 := c.entry(t, "opencode-grok-native", "coding_complex")
	want(t, "grok 4.5 capped", []any{g45["score"], g45["basis"], g45["live"]}, []any{80.0, "capped", false})
	// The local model takes no other Qwen row (3.8-27B is #43).
	local := c.entry(t, "litellm-local-coding", "coding_complex")
	want(t, "local model capped", []any{local["rank"], local["score"], local["basis"]}, []any{nil, 80.0, "capped"})

	review := c.entry(t, "claude-opus-native", "coding_review")
	want(t, "review is the measured agent score", []any{review["score"], review["basis"], review["rank"]}, []any{97.1, "measured", 2.0})
	if review["score"] == baseScore(t, "claude-opus-native", "coding_review") {
		t.Error("the review score is still the built-in estimate")
	}
	std := c.entry(t, "claude-opus-native", "coding_standard")
	// No feed measures it: the catalog's entry is left as it is.
	want(t, "standard coding stays the fixed figure", []any{std["score"], std["live"], std["basis"]}, []any{baseScore(t, "claude-opus-native", "coding_standard"), nil, nil})

	// A frontier-reserved model keeps its fixed coding score but takes a
	// measured webdev score for its own version (5.2 is #1, 5.1 is #7).
	fable := c.entry(t, "claude-fable-native", "coding_complex")
	want(t, "fable coding fixed", []any{fable["score"], fable["basis"]}, []any{baseScore(t, "claude-fable-native", "coding_complex"), nil})
	fwd := c.entry(t, "claude-fable-native", "webdev")
	want(t, "fable webdev", []any{fwd["rank"], fwd["score"], fwd["benchmark"]}, []any{1.0, 97.5, "LMArena WebDev #1 (1990 Elo)"})

	for _, cand := range c.Candidates {
		if cand.ID != "claude-mythos-native" {
			continue
		}
		for class, e := range cand.Benchmarks {
			if e["basis"] != nil {
				t.Errorf("security specialist %s was rescored: %v", class, e)
			}
		}
	}

	arch := c.entry(t, "claude-opus-native", "architecture")
	want(t, "architecture blends agent and reasoning (97.1*0.6 + 94.8*0.4)", []any{arch["score"], arch["text_score"]}, []any{96.2, 94.8})

	astra := c.entry(t, "codex-astra-native", "coding_complex")
	want(t, "a row whose rank is not a number is dropped", astra["rank"], 6.0)

	want(t, "unmatched", *rec.Unmatched, []string{"opencode-grok-native", "litellm-local-coding"})
	if *rec.LiveScores == 0 || rec.Feeds.SWEBench != "not_scored" || rec.Feeds.ArtificialAnalysis != "not_used" {
		t.Errorf("receipt: %+v %+v", rec, rec.Feeds)
	}
	want(t, "models.dev window", c.window(t, "claude-opus-native"), 2000000.0)
	want(t, "a model models.dev lists without a window keeps the catalog's", c.window(t, "claude-sonnet-native"), 1000000.0)

	left, _ := filepath.Glob(filepath.Join(filepath.Dir(out), "*.tmp.*"))
	if len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}
}

func TestSyncCarriesScoresWhileAFeedIsDown(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	sync(t, out, fixtures(t, allFeeds...), t0, 0)
	first := read(t, out).entry(t, "agy-carbon-native", "research")

	// The reasoning board is down an hour later.
	later := t0.Add(time.Hour)
	rec, rc := sync(t, out, fixtures(t, FeedAgent, FeedWebdev), later, 0)
	want(t, "exit", rc, ExitSynced)
	want(t, "text feed", rec.Feeds.Text, "offline")
	c := read(t, out)
	res := c.entry(t, "agy-carbon-native", "research")
	want(t, "research carried with its first sync time", []any{res["basis"], res["rank"], res["synced_epoch"]},
		[]any{"measured", 1.0, first["synced_epoch"]})
	arch := c.entry(t, "claude-opus-native", "architecture")
	want(t, "architecture keeps the carried reasoning half", []any{arch["score"], arch["text_score"]}, []any{96.2, 94.8})
	want(t, "models.dev down: the window is the last sync's", c.window(t, "claude-opus-native"), 2000000.0)

	// Past the carry window, a carried score falls back to the estimate.
	rec, _ = sync(t, out, fixtures(t, FeedAgent, FeedWebdev), later.Add(1000*time.Second), 500*time.Second)
	res = read(t, out).entry(t, "agy-carbon-native", "research")
	want(t, "expired carry", []any{res["basis"], res["score"]}, []any{"estimate", baseScore(t, "agy-carbon-native", "research")})
	_ = rec
}

func TestSyncWithTheAgentBoardDownCarriesReviewAndKeepsOwnWindow(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	sync(t, out, fixtures(t, allFeeds...), t0, 0)
	score := read(t, out).entry(t, "claude-opus-native", "coding_review")["score"]
	// The previous catalog claims an old 131K window for the local model.
	b, _ := os.ReadFile(out)
	b = []byte(strings.Replace(string(b), `"window_tokens": 65536`, `"window_tokens": 131072`, 1))
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}
	sync(t, out, fixtures(t, FeedWebdev), t0.Add(time.Minute), 0)
	c := read(t, out)
	r := c.entry(t, "claude-opus-native", "coding_review")
	want(t, "review carried", []any{r["score"], r["basis"]}, []any{score, "measured"})
	want(t, "the local model keeps its own window", c.window(t, "litellm-local-coding"), 65536.0)
}

func TestCarryZeroKeepsNothing(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	sync(t, out, fixtures(t, allFeeds...), t0, 0)
	// AFK_BENCHMARK_CARRY_SEC=0: with the text board down a minute later,
	// its research score is not carried.
	Sync(context.Background(), Options{Base: router.DefaultCatalogJSON(), Out: out, Now: t0.Add(time.Minute), Carry: 0,
		Feeds: fixtures(t, FeedAgent, FeedWebdev)})
	res := read(t, out).entry(t, "agy-carbon-native", "research")
	want(t, "no carry", []any{res["basis"], res["score"]}, []any{"estimate", baseScore(t, "agy-carbon-native", "research")})
}

func TestWindowIsCarriedOnlyForTheSameModel(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	sync(t, out, fixtures(t, allFeeds...), t0, 0)
	// The previous catalog had opus under another models.dev id (a model
	// upgrade under the same candidate id), with a window of its own.
	b := mustRead(t, out)
	b = []byte(strings.Replace(string(b), `"models_dev_id": "claude-opus-5-5"`, `"models_dev_id": "claude-opus-5-1"`, 1))
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}
	sync(t, out, fixtures(t, FeedAgent), t0.Add(time.Minute), 0)
	want(t, "the built-in window, not the other model's", read(t, out).window(t, "claude-opus-native"), 1000000.0)

	// Same model: models.dev down, the last sync's window is kept.
	sync(t, out, fixtures(t, allFeeds...), t0.Add(2*time.Minute), 0)
	sync(t, out, fixtures(t, FeedAgent), t0.Add(3*time.Minute), 0)
	want(t, "same model carries", read(t, out).window(t, "claude-opus-native"), 2000000.0)
}

func TestSyncWithNoBoardLeavesTheCatalogAlone(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	sync(t, out, fixtures(t, allFeeds...), t0, 0)
	before, _ := os.ReadFile(out)

	rec, rc := sync(t, out, mapFeeds{}, t0.Add(time.Hour), 0)
	want(t, "exit", rc, ExitUnavailable)
	want(t, "result", rec.Result, "feeds_unavailable")
	after, _ := os.ReadFile(out)
	if string(before) != string(after) {
		t.Error("the catalog changed with no board reachable")
	}
	if *rec.LiveScores == 0 {
		t.Error("the receipt should count the kept measured scores")
	}

	// An HTML error page, an error object and an empty board are all
	// unreachable boards.
	broken := mapFeeds{
		FeedAgent:  []byte("<html>503 Service Unavailable</html>"),
		FeedWebdev: []byte(`{"error":"Job has been terminated"}`),
		FeedText:   []byte(`{"rows":[]}`),
	}
	_, rc = sync(t, out, broken, t0.Add(2*time.Hour), 0)
	want(t, "broken feeds exit", rc, ExitUnavailable)
	after, _ = os.ReadFile(out)
	if string(before) != string(after) {
		t.Error("broken feeds changed the catalog")
	}
}

func TestSyncWithNoBoardAndNoCatalogWritesEstimates(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	rec, rc := sync(t, out, mapFeeds{}, t0, 0)
	want(t, "exit", rc, ExitUnavailable)
	c := read(t, out)
	var base catalog
	_ = json.Unmarshal(router.DefaultCatalogJSON(), &base)
	want(t, "every candidate", len(c.Candidates), len(base.Candidates))
	want(t, "nothing measured", *rec.LiveScores, 0)
	// The router reads what the sync wrote.
	if _, err := router.ParseCatalog(mustRead(t, out)); err != nil {
		t.Fatal(err)
	}
}

func TestSyncRefusesAnUnreadableBase(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	rec, rc := Sync(context.Background(), Options{Base: []byte("{}"), Out: out, Now: t0, Feeds: mapFeeds{}})
	want(t, "exit", rc, ExitError)
	want(t, "result", rec.Result, "error")
	if _, err := os.Stat(out); err == nil {
		t.Error("wrote a catalog from a bad base")
	}
}

func TestParseBoard(t *testing.T) {
	rows, ok := ParseBoard([]byte(`{"rows":[
		{"row":{"model_name":"A (Max)","rank":2,"score":1500,"leaderboard_publish_date":"2026-11-11"}},
		{"row":{"model_name":"B","rank":"n/a","score":1}},
		{"row":{"model_name":"C","rank":3,"category":"coding","rating":1400}},
		{"row":{"model_name":"D","rank":4,"category":"Overall","rating":1300}},
		{"row":null}
	]}`))
	if !ok || len(rows) != 2 {
		t.Fatalf("rows %v ok %v", rows, ok)
	}
	want(t, "first", rows[0], Row{Name: "A (Max)", Rank: 2, Value: 1500.0, Date: "2026-11-11"})
	want(t, "rating used when there is no score", rows[1].Value, 1300.0)
	for _, bad := range []string{"", "<html>", `{"error":"x"}`, `{"rows":[]}`, `null`} {
		if _, ok := ParseBoard([]byte(bad)); ok {
			t.Errorf("%q counted as a reachable board", bad)
		}
	}
}

func TestNormAndBest(t *testing.T) {
	for in, out := range map[string]string{
		"Claude Opus 5.5 (Max)":        "claude opus 5.5",
		"GPT-6 Astra (High, thinking)": "gpt 6 astra",
		"Grok 4.7 (xHigh)":             "grok 4.7",
		"Qwen3.8-Max":                  "qwen3.8 max",
		"Model (2026-01-01)":           "model 2026 01 01",
	} {
		want(t, in, Norm(in), out)
	}
	rows := []Row{{Name: "Grok 4.7 (xHigh)", Rank: 17}, {Name: "Claude Opus 5.5 (High)", Rank: 9}, {Name: "Claude Opus 5.5 (Max)", Rank: 2}}
	want(t, "best-ranked variant", Best(rows, "Claude Opus 5.5").Rank, 2.0)
	if Best(rows, "Grok 4.5") != nil || Best(rows, "Grok") != nil || Best(rows, "") != nil {
		t.Error("a partial or empty name matched")
	}
	want(t, "rank 1", RankScore(98, 1), 98.0)
	want(t, "floor", RankScore(98, 40), 80.0)
}
func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDueAndAutoSync(t *testing.T) {
	home := t.TempDir()
	env := map[string]string{}
	e := Env{Home: home, Getenv: func(k string) string { return env[k] }}
	calls := 0
	run := func(context.Context) int { calls++; return ExitUnavailable }
	cat := CatalogPath(home)

	// A missing catalog: one attempt, then the retry window holds.
	for i := 0; i < 3; i++ {
		AutoSync(context.Background(), e, run)
	}
	want(t, "missing catalog syncs once", calls, 1)

	env["AFK_BENCHMARK_RETRY_SEC"] = "0"
	AutoSync(context.Background(), e, run)
	want(t, "past the retry window it tries again", calls, 2)
	delete(env, "AFK_BENCHMARK_RETRY_SEC")

	// A fresh catalog with measured scores is not synced.
	sync(t, cat, fixtures(t, allFeeds...), time.Now(), 0)
	_ = os.Remove(cat + ".sync-attempt")
	AutoSync(context.Background(), e, run)
	want(t, "fresh catalog", calls, 2)

	env["AFK_BENCHMARK_TTL_SEC"] = "0"
	for i := 0; i < 3; i++ {
		AutoSync(context.Background(), e, run)
	}
	want(t, "past its TTL: once, not on every call", calls, 3)

	_ = os.Remove(cat + ".sync-attempt")
	env["AFK_BENCHMARK_TTL_SEC"], env["AFK_BENCHMARK_RETRY_SEC"] = "not-a-number", "junk"
	AutoSync(context.Background(), e, run)
	want(t, "bad numbers fall back to the defaults", calls, 3)

	_ = os.Remove(cat + ".sync-attempt")
	env["AFK_BENCHMARK_TTL_SEC"], env["AFK_SKIP_BENCHMARK_AUTOSYNC"] = "0", "1"
	if Due(e) {
		t.Error("AFK_SKIP_BENCHMARK_AUTOSYNC=1 should turn it off")
	}
	delete(env, "AFK_SKIP_BENCHMARK_AUTOSYNC")
	env["AFK_ROUTER_BENCHMARKS_FILE"] = "/elsewhere.json"
	if Due(e) {
		t.Error("a catalog of your own is never synced over")
	}
	delete(env, "AFK_ROUTER_BENCHMARKS_FILE")

	// Another process holds the lock: this one carries on without a sync.
	if err := os.Mkdir(cat+".sync-attempt.lock", 0o755); err != nil {
		t.Fatal(err)
	}
	AutoSync(context.Background(), e, run)
	want(t, "lock held", calls, 3)
	_ = os.Remove(cat + ".sync-attempt.lock")
	AutoSync(context.Background(), e, run)
	want(t, "lock free", calls, 4)

	// The attempt marker can't be written: no sync, or every route would
	// start one.
	_ = os.Remove(cat + ".sync-attempt")
	if err := os.Mkdir(cat+".sync-attempt", 0o755); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(cat+".sync-attempt", old, old)
	AutoSync(context.Background(), e, run)
	want(t, "unwritable marker", calls, 4)
}
