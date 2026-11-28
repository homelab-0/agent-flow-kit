package bench

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/router"
)

func TestLooseNormMatchesAcrossBoards(t *testing.T) {
	same := [][2]string{
		{"Claude 5.5 Opus", "Claude Opus 5.5"},
		{"claude-opus-5-5", "Claude Opus 5.5"},
		{"Claude Opus 5.5 (high)", "claude-opus-5-5"},
		{"claude-sonnet-5-5-20261001", "Claude Sonnet 5.5"},
		{"gpt-4o-mini-2024-07-18", "GPT 4o mini"},
		{"Gemini 4 Carbon Preview", "gemini-4-carbon"},
	}
	for _, p := range same {
		if LooseNorm(p[0]) != LooseNorm(p[1]) {
			t.Errorf("%q and %q should match: %q vs %q", p[0], p[1], LooseNorm(p[0]), LooseNorm(p[1]))
		}
	}
	differ := [][2]string{
		{"Grok 4.5", "Grok 4.7"},
		{"GPT 6.1 Sol", "GPT 6.1 Sol Codex"},
		{"Claude Opus 5", "Claude Opus 5.5"},
	}
	for _, p := range differ {
		if LooseNorm(p[0]) == LooseNorm(p[1]) {
			t.Errorf("%q and %q must not match", p[0], p[1])
		}
	}
}

func TestReadBoardFormats(t *testing.T) {
	js := `{"boards":[{"name":"Lite","results":[{"model_display":"A","resolved":99}]},
	  {"name":"Verified","results":[
	    {"model_display":"Claude 5.5 Opus","resolved":"71.0%"},
	    {"model_display":"Claude 5.5 Opus","resolved":76.5},
	    {"model_display":"GPT-6 Astra","resolved":76.5},
	    {"model_display":"Grok 4.7","resolved":60},
	    {"model_display":"","resolved":90},
	    {"model_display":"No score"}]}]}`
	bd, err := ReadBoard(Source{Rows: "boards[name=Verified].results", Model: "model_display", Score: "resolved"}, []byte(js))
	if err != nil {
		t.Fatal(err)
	}
	if len(bd.Rows) != 3 {
		t.Fatalf("rows: %+v", bd.Rows)
	}
	// A model's best result counts, and equal results share a rank.
	want(t, "first", bd.Rows[0].Name+" "+numText(bd.Rows[0].Rank), "Claude 5.5 Opus 1")
	want(t, "tie", bd.Rows[1].Rank, 1.0)
	want(t, "third", bd.Rows[2].Rank, 3.0)

	// Nothing named: the largest list and its fields are found.
	bd, err = ReadBoard(Source{}, []byte(js))
	if err != nil {
		t.Fatal(err)
	}
	want(t, "detected rows", bd.Rows0, "boards.1.results")
	want(t, "detected model", bd.Model, "model_display")
	want(t, "detected score", bd.Score, "resolved")

	yml := "# board\n- dirname: one\n  model: gpt-6-astra (high)\n  pass_rate_2: 80.1\n  nested:\n    a: 1\n- dirname: two\n  model: \"Grok 4.7\"\n  pass_rate_2: 70 # note\n"
	bd, err = ReadBoard(Source{File: "x.yml"}, []byte(yml))
	if err != nil {
		t.Fatal(err)
	}
	want(t, "yaml model field", bd.Model, "model")
	want(t, "yaml score field", bd.Score, "pass_rate_2")
	want(t, "yaml rows", len(bd.Rows), 2)
	want(t, "yaml first", bd.Rows[0].Name, "gpt-6-astra (high)")

	csvDoc := "Model,Latency (s)\nGrok 4.7,3.1\nClaude Opus 5.5,1.2\n"
	bd, err = ReadBoard(Source{URL: "https://x/board.csv", Model: "Model", Score: "Latency (s)", Lower: true}, []byte(csvDoc))
	if err != nil {
		t.Fatal(err)
	}
	want(t, "lower is better", bd.Rows[0].Name, "Claude Opus 5.5")

	if _, err := ReadBoard(Source{Rows: "nope"}, []byte(js)); err == nil || !strings.Contains(err.Error(), "nothing at") {
		t.Errorf("a missing path: %v", err)
	}
	if _, err := ReadBoard(Source{Format: "yaml"}, []byte("a: [1, 2\n  b")); err == nil {
		t.Error("broken YAML should fail")
	}
}

func TestPresetsParseTheRealShapes(t *testing.T) {
	// Trimmed copies of the real files.
	swe := `{"leaderboards":[{"name":"Verified","results":[
	  {"name":"Agent X + Claude 4.5 Opus","model_display":"Claude 4.5 Opus","resolved":79.2,"tags":["Model: claude-opus-4-5"]},
	  {"name":"Agent Y + Claude 4.5 Opus","model_display":"Claude 4.5 Opus","resolved":76.8}]}]}`
	aider := "- dirname: 2025-10-03--deepseek\n  test_cases: 225\n  model: DeepSeek-V3.2-Exp (Chat)\n  edit_format: diff\n  pass_rate_1: 38.7\n  pass_rate_2: 70.2\n  date: 2025-10-03\n"
	for _, p := range Presets() {
		var doc string
		switch p.ID {
		case "swebench":
			doc = swe
		case "aider":
			doc = aider
		default:
			continue
		}
		bd, err := ReadBoard(p, []byte(doc))
		if err != nil {
			t.Fatalf("%s: %v", p.ID, err)
		}
		if len(bd.Rows) != 1 {
			t.Errorf("%s: %+v", p.ID, bd.Rows)
		}
	}
}

// srcFeeds serves boards and sources by name; a missing name is offline.
type srcFeeds struct {
	mapFeeds
	src map[string][]byte
}

func (f srcFeeds) FetchSource(_ context.Context, s Source) ([]byte, error) {
	if b, ok := f.src[s.ID]; ok {
		return b, nil
	}
	return nil, os.ErrNotExist
}

func TestSyncBlendsSources(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	board := []byte(`{"rows":[{"model":"GPT-6 Astra","pct":80},{"model":"Claude 5.5 Opus","pct":75},{"model":"Old Model","pct":50}]}`)
	src := Source{ID: "evals", Name: "Evals", Tasks: []string{"coding_complex", "coding_standard"}, Weight: 1}
	feeds := srcFeeds{fixtures(t, allFeeds...), map[string][]byte{"evals": board}}
	opts := Options{Base: router.DefaultCatalogJSON(), Out: out, Now: t0, Carry: DefaultCarry, Feeds: feeds, Sources: []Source{src}}
	rec, rc := Sync(context.Background(), opts)
	want(t, "exit", rc, ExitSynced)
	if got := rec.Feeds.Sources["evals"]; !strings.Contains(got, "3 models") || !strings.Contains(got, "matched") {
		t.Errorf("receipt: %q", got)
	}
	c := read(t, out)

	// Opus is on LMArena's agent board and second on this one: the score
	// is the average of the two, with both parts kept.
	cc := c.entry(t, "claude-opus-native", "coding_complex")
	want(t, "feed", cc["feed"], "blend")
	parts, _ := cc["parts"].([]any)
	if len(parts) != 2 {
		t.Fatalf("parts: %v", cc["parts"])
	}
	arena, own := parts[0].(map[string]any), parts[1].(map[string]any)
	want(t, "arena first", arena["source"], "lmarena")
	want(t, "own second", own["source"], "evals")
	want(t, "own score", own["score"], RankScore(97.5, 2))
	want(t, "average", cc["score"], r1((arena["score"].(float64)+own["score"].(float64))/2))
	if !strings.Contains(cc["benchmark"].(string), "Evals #2 (75)") {
		t.Errorf("label: %v", cc["benchmark"])
	}

	// coding_standard has no LMArena board: the measurement replaces the
	// estimate rather than being averaged with it.
	cs := c.entry(t, "claude-opus-native", "coding_standard")
	want(t, "standard score", cs["score"], RankScore(97.5, 2))
	want(t, "standard live", cs["live"], true)
	want(t, "one part", len(cs["parts"].([]any)), 1)

	// A model the board doesn't list keeps what it had.
	g := c.entry(t, "grok-4.7-native", "coding_standard")
	want(t, "unlisted", g["live"] == true, false)
	want(t, "unlisted score", g["score"], baseScore(t, "grok-4.7-native", "coding_standard"))

	// Weight 0 leaves LMArena out of the blend for complex work.
	opts.Weights = map[string]map[string]float64{"coding_complex": {"lmarena": 0}}
	Sync(context.Background(), opts)
	c = read(t, out)
	cc = c.entry(t, "claude-opus-native", "coding_complex")
	want(t, "weighted out", cc["score"], RankScore(97.5, 2))
	want(t, "still listed", len(cc["parts"].([]any)), 2)

	// The source is down the next day: its part is carried, marked so.
	opts.Weights = nil
	opts.Now = t0.Add(24 * 60 * 60 * 1e9)
	opts.Feeds = srcFeeds{fixtures(t, allFeeds...), nil}
	rec, _ = Sync(context.Background(), opts)
	if !strings.HasPrefix(rec.Feeds.Sources["evals"], "unavailable") {
		t.Errorf("down: %q", rec.Feeds.Sources["evals"])
	}
	c = read(t, out)
	cs = c.entry(t, "claude-opus-native", "coding_standard")
	p0 := cs["parts"].([]any)[0].(map[string]any)
	want(t, "carried", p0["carried"], true)
	want(t, "carried score", cs["score"], RankScore(97.5, 2))
}

func TestReadBoardEdgeCases(t *testing.T) {
	// NaN and Inf are not scores, so a real result still wins.
	js := `[{"model":"A","score":"NaN"},{"model":"A","score":90},{"model":"B","score":"Inf"},{"model":"C","score":80}]`
	bd, err := ReadBoard(Source{}, []byte(js))
	if err != nil {
		t.Fatal(err)
	}
	if len(bd.Rows) != 2 || bd.Rows[0].Value != 90.0 {
		t.Errorf("non-finite: %+v", bd.Rows)
	}
	// The score field is found even when the first record lacks it.
	js = `[{"model":"A","cost":1},{"model":"B","score":90,"cost":10},{"model":"C","score":80,"cost":20}]`
	bd, err = ReadBoard(Source{}, []byte(js))
	if err != nil || bd.Score != "score" || len(bd.Rows) != 2 || bd.Rows[0].Name != "B" {
		t.Errorf("detect across records: %v %+v", err, bd)
	}
	// Block scalars and quoted escapes.
	yml := "- model: \"GPT\\u002d6 Astra\"\n  notes: |\n    line one: with a colon\n    - not a list\n  score: 70\n- model: 'Grok ''4.7'''\n  score: 60\n"
	bd, err = ReadBoard(Source{Format: "yaml"}, []byte(yml))
	if err != nil {
		t.Fatal(err)
	}
	want(t, "unescaped", bd.Rows[0].Name, "GPT-6 Astra")
	want(t, "single quotes", bd.Rows[1].Name, "Grok '4.7'")
}

func TestFetchSourceGuards(t *testing.T) {
	var hits int
	other := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("x-key") != "" {
			t.Error("the key reached another host")
		}
	}))
	defer other.Close()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/away":
			http.Redirect(w, r, other.URL+"/board.json", http.StatusFound)
		case "/big":
			w.Write(make([]byte, maxFeed+10))
		default:
			w.Write([]byte(`[{"model":"A","score":1}]`))
		}
	}))
	defer srv.Close()
	h := HTTPFetcher{Client: srv.Client()}
	keyed := Source{URL: srv.URL + "/away", Key: "k", KeyHeader: "x-key", KeyEnv: "K"}
	if _, err := h.FetchSource(context.Background(), keyed); err == nil || !strings.Contains(err.Error(), "another host") && !strings.Contains(err.Error(), "reach") {
		t.Errorf("keyed redirect: %v", err)
	}
	if hits != 0 {
		t.Error("followed the redirect with a key")
	}
	if _, err := h.FetchSource(context.Background(), Source{URL: srv.URL + "/big"}); err == nil {
		t.Error("an oversized feed was read")
	}
	if _, err := h.FetchSource(context.Background(), Source{URL: "https://user:pw@example.invalid/b.json"}); err == nil || strings.Contains(err.Error(), "pw") {
		t.Errorf("user info: %v", err)
	}
	if hostOf("https://user:pw@example.invalid:8443/x") != "example.invalid:8443" {
		t.Error("hostOf kept user info")
	}
}

func TestBlendFallsBackWhenPartsGo(t *testing.T) {
	out := filepath.Join(t.TempDir(), "benchmarks.json")
	board := []byte(`[{"model":"Claude Opus 5.5","pct":75},{"model":"GPT-6 Astra","pct":80}]`)
	src := Source{ID: "evals", Name: "Evals", Tasks: []string{"coding_complex", "coding_standard"}, Weight: 1}
	opts := Options{Base: router.DefaultCatalogJSON(), Out: out, Now: t0, Carry: DefaultCarry, Sources: []Source{src},
		Feeds: srcFeeds{fixtures(t, allFeeds...), map[string][]byte{"evals": board}}}
	Sync(context.Background(), opts)

	// The agent board down and the source turned off: no composite is kept.
	opts.Now = t0.Add(24 * time.Hour)
	opts.Sources = nil
	opts.Feeds = srcFeeds{fixtures(t, FeedWebdev, FeedModelsDev), nil}
	Sync(context.Background(), opts)
	c := read(t, out)
	cs := c.entry(t, "claude-opus-native", "coding_standard")
	if cs["feed"] == "blend" || cs["live"] == true {
		t.Errorf("a turned-off source still scores: %v", cs)
	}
	// The LMArena part of the old blend stays as LMArena alone.
	cc := c.entry(t, "claude-opus-native", "coding_complex")
	if cc["feed"] == "blend" || cc["live"] != true {
		t.Errorf("complex should be LMArena alone: %v", cc)
	}

	// Weighted out while LMArena is down: the estimate, not the old score.
	opts.Sources = []Source{src}
	opts.Feeds = srcFeeds{fixtures(t, allFeeds...), map[string][]byte{"evals": board}}
	opts.Now = t0.Add(48 * time.Hour)
	Sync(context.Background(), opts)
	opts.Weights = map[string]map[string]float64{"coding_standard": {"evals": 0}}
	opts.Feeds = srcFeeds{fixtures(t, FeedWebdev, FeedModelsDev), nil}
	opts.Now = t0.Add(72 * time.Hour)
	Sync(context.Background(), opts)
	c = read(t, out)
	cs = c.entry(t, "claude-opus-native", "coding_standard")
	want(t, "weighted out", cs["score"], baseScore(t, "claude-opus-native", "coding_standard"))

	// A carried LMArena part past its own window drops out of the blend.
	opts.Weights = nil
	opts.Feeds = srcFeeds{fixtures(t, FeedWebdev, FeedModelsDev), map[string][]byte{"evals": board}}
	opts.Now = t0.Add(20 * 24 * time.Hour)
	Sync(context.Background(), opts)
	c = read(t, out)
	cc = c.entry(t, "claude-opus-native", "coding_complex")
	for _, p := range anyList(cc["parts"]) {
		if p.(map[string]any)["source"] == "lmarena" {
			t.Errorf("stale LMArena part kept: %v", cc)
		}
	}
	want(t, "source alone", cc["score"], RankScore(97.5, 2))
}
