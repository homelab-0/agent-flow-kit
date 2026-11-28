package bench

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// A Source is one leaderboard beyond the LMArena boards: a built-in preset
// (SWE-bench Verified, Aider Polyglot, Artificial Analysis) or one the
// user added in config.toml under [bench.custom.<id>]. Every source is read
// the same way: fetch a JSON, YAML or CSV document, pick its rows, take a
// model name and a score from each, and match the names to the catalog.
//
// A source turns a model's place on its board into a score the same way
// the LMArena boards do (RankScore), so scores from different boards are
// on one scale and can be averaged.
type Source struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// URL is fetched with a plain GET; File is read from disk instead.
	URL  string `json:"url,omitempty"`
	File string `json:"file,omitempty"`
	// Format is json, yaml or csv; empty means from the URL's or file's
	// extension, else json.
	Format string `json:"format,omitempty"`
	// Rows is where the records are: a dotted path, with [field=value] to
	// pick one element of a list ("leaderboards[name=Verified].results").
	// Empty means the document itself, or its largest list of records.
	Rows string `json:"rows,omitempty"`
	// Model and Score are the fields (dotted for nested ones) holding the
	// model's name and its result. Empty means detect them.
	Model string `json:"model,omitempty"`
	Score string `json:"score,omitempty"`
	// Lower is a board where a smaller result is better.
	Lower bool `json:"lower,omitempty"`
	// Tasks are the kinds of task the board's score counts for.
	Tasks []string `json:"tasks"`
	// Weight is the source's weight in a blend (default 1); config can set
	// one per task kind too.
	Weight float64 `json:"weight"`
	// KeyHeader and KeyEnv send an API key the user gave: the value of
	// the environment variable KeyEnv, in the header KeyHeader. Key is the
	// value itself, read by the caller and never written anywhere.
	KeyHeader string `json:"key_header,omitempty"`
	KeyEnv    string `json:"key_env,omitempty"`
	Key       string `json:"-"`
	// Measures and About describe the board for people.
	Measures string `json:"measures,omitempty"`
	About    string `json:"about,omitempty"`
	Builtin  bool   `json:"builtin,omitempty"`
	// On is whether config turns the source on (presets have a default).
	On bool `json:"on"`
}

// TaskKinds are the task kinds a source can score.
var TaskKinds = []string{"coding_complex", "coding_standard", "coding_review", "architecture", "security", "webdev", "research", "frontier_synthesis"}

// Presets are the built-in sources, with whether each is on by default.
// LMArena and models.dev are read by the sync itself and are not listed.
func Presets() []Source {
	return []Source{
		{ID: "swebench", Name: "SWE-bench Verified", Builtin: true, On: true,
			URL:      "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json",
			Rows:     "leaderboards[name=Verified].results",
			Model:    "model_display",
			Score:    "resolved",
			Tasks:    []string{"coding_complex", "coding_standard", "coding_review"},
			Weight:   1,
			Measures: "% of real GitHub issues solved",
			About:    "The share of 500 real GitHub issues a model resolves with its own patch, from the official SWE-bench leaderboard. A model can appear with several agents; AFK takes its best result."},
		{ID: "aider", Name: "Aider Polyglot", Builtin: true, On: true,
			URL:      "https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml",
			Model:    "model",
			Score:    "pass_rate_2",
			Tasks:    []string{"coding_standard", "coding_complex"},
			Weight:   1,
			Measures: "% of coding exercises passed",
			About:    "Aider's polyglot benchmark: 225 hard Exercism exercises in C++, Go, Java, JavaScript, Python and Rust, with a second try after seeing the test output."},
		{ID: "artificialanalysis", Name: "Artificial Analysis", Builtin: true, On: false,
			URL:       "https://artificialanalysis.ai/api/v2/language/models/free",
			Rows:      "data",
			Model:     "name",
			Score:     "evaluations.artificial_analysis_intelligence_index",
			Tasks:     []string{"research", "frontier_synthesis", "architecture"},
			Weight:    1,
			KeyHeader: "x-api-key",
			KeyEnv:    "ARTIFICIAL_ANALYSIS_API_KEY",
			Measures:  "Intelligence Index",
			About:     "Data from artificialanalysis.ai. Its free API needs your own free key (allows 100 requests a day; AFK makes one per sync) in ARTIFICIAL_ANALYSIS_API_KEY. AFK reads the key only when it syncs, sends it only to artificialanalysis.ai and never stores it."},
	}
}

// IDRE is a source id: lower case letters, digits and dashes.
var IDRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// SourceFetcher reads a Source's document.
type SourceFetcher interface {
	FetchSource(ctx context.Context, s Source) ([]byte, error)
}

// FetchSource is a GET of the source's URL with a 20-second limit (a
// leaderboard file can be several megabytes), or a read of its file. The
// only header AFK adds is the source's own key header, when it has a key.
func (h HTTPFetcher) FetchSource(ctx context.Context, s Source) ([]byte, error) {
	if s.File != "" {
		return readSourceFile(s.File)
	}
	if !strings.HasPrefix(s.URL, "https://") && !isLoopbackHTTP(s.URL) {
		return nil, errors.New("only https:// URLs (or http:// on this machine) are read")
	}
	if s.KeyEnv != "" && s.Key == "" {
		return nil, fmt.Errorf("needs a key in %s", s.KeyEnv)
	}
	cl := h.Client
	if cl == nil {
		cl = &http.Client{Timeout: 20 * time.Second}
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.URL, nil)
	if err != nil {
		return nil, err
	}
	if s.Key != "" && s.KeyHeader != "" {
		req.Header.Set(s.KeyHeader, s.Key)
	}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, errors.New("couldn't reach " + hostOf(s.URL))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, hostOf(s.URL))
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxFeed))
}

// FetchSource reads <dir>/source-<id>.json (or .yml, .csv) in tests, or
// the source's own file.
func (d DirFetcher) FetchSource(_ context.Context, s Source) ([]byte, error) {
	if s.File != "" {
		return readSourceFile(s.File)
	}
	for _, ext := range []string{".json", ".yml", ".csv"} {
		if b, err := os.ReadFile(filepath.Join(d.Dir, "source-"+s.ID+ext)); err == nil {
			return b, nil
		}
	}
	return nil, os.ErrNotExist
}

func readSourceFile(p string) ([]byte, error) {
	if strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		p = filepath.Join(home, p[2:])
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, errors.New("can't read " + p)
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, maxFeed))
}

func hostOf(u string) string {
	s := strings.TrimPrefix(strings.TrimPrefix(u, "https://"), "http://")
	if i := strings.IndexAny(s, "/?#"); i >= 0 {
		s = s[:i]
	}
	return s
}

func isLoopbackHTTP(u string) bool {
	h := hostOf(u)
	if i := strings.LastIndexByte(h, ':'); i >= 0 && !strings.HasSuffix(h, "]") {
		h = h[:i]
	}
	return strings.HasPrefix(u, "http://") && (h == "localhost" || h == "127.0.0.1" || h == "[::1]")
}

// FormatOf is the source's format: as set, else from the extension.
func (s Source) FormatOf() string {
	if s.Format != "" {
		return s.Format
	}
	p := s.File
	if p == "" {
		p = strings.SplitN(s.URL, "?", 2)[0]
	}
	switch strings.ToLower(filepath.Ext(p)) {
	case ".yml", ".yaml":
		return "yaml"
	case ".csv":
		return "csv"
	}
	return "json"
}

// Board is a source's rows, read: each model's best result.
type Board struct {
	Rows []Row
	// Model and Score are the fields used, after detection.
	Rows0, Model, Score string
}

// ReadBoard parses a source's document into one row per model: its best
// result, ranked (1 = best). An error says what couldn't be read.
func ReadBoard(s Source, b []byte) (Board, error) {
	doc, err := decodeDoc(s.FormatOf(), b)
	if err != nil {
		return Board{}, err
	}
	rowsPath, model, score := s.Rows, s.Model, s.Score
	var recs []map[string]any
	if rowsPath != "" {
		v, ok := walk(doc, rowsPath)
		if !ok {
			return Board{}, fmt.Errorf("nothing at %q", rowsPath)
		}
		recs = records(v)
	} else {
		rowsPath, recs = largestList(doc, "")
	}
	if len(recs) == 0 {
		return Board{}, errors.New("no list of records found")
	}
	if model == "" || score == "" {
		dm, ds := detectFields(recs)
		if model == "" {
			model = dm
		}
		if score == "" {
			score = ds
		}
	}
	if model == "" || score == "" {
		return Board{}, errors.New("couldn't tell which fields hold the model and its score")
	}
	best := map[string]Row{}
	for _, r := range recs {
		nv, _ := walk(r, model)
		name := strings.TrimSpace(scalarText(nv))
		sv, _ := walk(r, score)
		val, ok := toNumber(sv)
		if name == "" || !ok {
			continue
		}
		k := LooseNorm(name)
		if k == "" {
			continue
		}
		cur, seen := best[k]
		if !seen || better(val, cur.Value.(float64), s.Lower) {
			best[k] = Row{Name: name, Value: val}
		}
	}
	if len(best) == 0 {
		return Board{}, fmt.Errorf("no record has both %s and a number in %s", model, score)
	}
	rows := make([]Row, 0, len(best))
	for _, r := range best {
		rows = append(rows, r)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i].Value.(float64), rows[j].Value.(float64)
		if a != b {
			return better(a, b, s.Lower)
		}
		return rows[i].Name < rows[j].Name
	})
	// Equal results share a rank.
	for i := range rows {
		if i > 0 && rows[i].Value.(float64) == rows[i-1].Value.(float64) {
			rows[i].Rank = rows[i-1].Rank
		} else {
			rows[i].Rank = float64(i + 1)
		}
	}
	return Board{Rows: rows, Rows0: rowsPath, Model: model, Score: score}, nil
}

func better(a, b float64, lower bool) bool {
	if lower {
		return a < b
	}
	return a > b
}

var (
	looseSplit = regexp.MustCompile(`[^a-z0-9]+`)
	dateToken  = regexp.MustCompile(`^(19|20)\d{6}$`)
)

// LooseNorm is a name compared across boards that write it differently
// ("Claude 4.5 Opus", "claude-opus-4-5", "Claude Opus 4.5 (high)"): lower
// case, without an effort suffix, a date or a preview/latest tag, split
// into words and sorted. Every word must match, so "Grok 4.5" still never
// matches "Grok 4.7" and "GPT 5.2" never matches "GPT 5.2 Codex".
func LooseNorm(s string) string {
	s = strings.ToLower(s)
	s = effortSuffix.ReplaceAllString(s, "")
	words := looseSplit.Split(s, -1)
	var keep []string
	for i := 0; i < len(words); i++ {
		w := words[i]
		switch {
		case w == "", w == "preview", w == "latest", w == "exp":
			continue
		case dateToken.MatchString(w):
			continue
		// 2024-07-18 written as three words.
		case len(w) == 4 && (strings.HasPrefix(w, "20")) && i+2 < len(words) && len(words[i+1]) == 2 && len(words[i+2]) == 2 && allDigits(w+words[i+1]+words[i+2]):
			i += 2
			continue
		}
		keep = append(keep, w)
	}
	sort.Strings(keep)
	return strings.Join(keep, " ")
}

func allDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}

// MatchBoard is the row for a model, by any of its names, or nil.
func MatchBoard(rows []Row, names ...string) *Row {
	for _, n := range names {
		k := LooseNorm(n)
		if k == "" {
			continue
		}
		for i := range rows {
			if LooseNorm(rows[i].Name) == k {
				return &rows[i]
			}
		}
	}
	return nil
}

func decodeDoc(format string, b []byte) (any, error) {
	switch format {
	case "csv":
		r := csv.NewReader(bytes.NewReader(b))
		r.FieldsPerRecord = -1
		all, err := r.ReadAll()
		if err != nil || len(all) < 2 {
			return nil, errors.New("not a CSV with a header and rows")
		}
		head := all[0]
		var out []any
		for _, rec := range all[1:] {
			m := map[string]any{}
			for i, h := range head {
				if i < len(rec) {
					m[strings.TrimSpace(h)] = rec[i]
				}
			}
			out = append(out, m)
		}
		return out, nil
	case "yaml":
		v, err := parseYAML(b)
		if err != nil {
			return nil, err
		}
		return v, nil
	case "json":
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		var v any
		if err := dec.Decode(&v); err != nil {
			return nil, errors.New("not JSON")
		}
		return v, nil
	}
	return nil, fmt.Errorf("unknown format %q (json, yaml or csv)", format)
}

var selRE = regexp.MustCompile(`^([^\[]*)\[([^=\]]+)=([^\]]*)\]$`)

// walk follows a dotted path: a key, a list index, or key[field=value] to
// take the first element of the list whose field equals value.
func walk(v any, path string) (any, bool) {
	if path == "" {
		return v, true
	}
	for _, part := range splitPath(path) {
		key, field, want := part, "", ""
		sel := false
		if m := selRE.FindStringSubmatch(part); m != nil {
			key, field, want, sel = m[1], m[2], m[3], true
		}
		if key != "" {
			switch c := v.(type) {
			case map[string]any:
				nv, ok := c[key]
				if !ok {
					return nil, false
				}
				v = nv
			case []any:
				i, err := strconv.Atoi(key)
				if err != nil || i < 0 || i >= len(c) {
					return nil, false
				}
				v = c[i]
			default:
				return nil, false
			}
		}
		if sel {
			l, ok := v.([]any)
			if !ok {
				return nil, false
			}
			found := false
			for _, e := range l {
				if m, ok := e.(map[string]any); ok && scalarText(m[field]) == want {
					v, found = m, true
					break
				}
			}
			if !found {
				return nil, false
			}
		}
	}
	return v, true
}

// splitPath splits on dots outside [ ].
func splitPath(p string) []string {
	var out []string
	depth, start := 0, 0
	for i, r := range p {
		switch r {
		case '[':
			depth++
		case ']':
			depth--
		case '.':
			if depth == 0 {
				out = append(out, p[start:i])
				start = i + 1
			}
		}
	}
	return append(out, p[start:])
}

func records(v any) []map[string]any {
	l, _ := v.([]any)
	var out []map[string]any
	for _, e := range l {
		if m, ok := e.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// largestList is the longest list of records anywhere in the document,
// and its path.
func largestList(v any, path string) (string, []map[string]any) {
	bestPath, best := "", []map[string]any(nil)
	if r := records(v); len(r) > 0 {
		bestPath, best = path, r
	}
	visit := func(p string, c any) {
		if bp, b := largestList(c, p); len(b) > len(best) {
			bestPath, best = bp, b
		}
	}
	switch c := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(c))
		for k := range c {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			p := k
			if path != "" {
				p = path + "." + k
			}
			visit(p, c[k])
		}
	case []any:
		for i, e := range c {
			if _, ok := e.(map[string]any); !ok {
				continue
			}
			p := strconv.Itoa(i)
			if path != "" {
				p = path + "." + p
			}
			visit(p, e)
		}
	}
	return bestPath, best
}

var (
	modelNames = []string{"model", "model_name", "model_display", "modelname", "name", "model_id", "id", "llm"}
	scoreNames = []string{"score", "overall", "average", "avg", "rating", "elo", "accuracy", "resolved", "pass_rate", "pass_rate_2", "pass@1", "win_rate", "intelligence_index"}
)

// detectFields picks the model and score fields of the records: a text
// field with a model-like name, and a number field with a score-like name,
// else the first number field.
func detectFields(recs []map[string]any) (model, score string) {
	first := recs[0]
	lower := map[string]string{}
	keys := make([]string, 0, len(first))
	for k := range first {
		keys = append(keys, k)
		lower[strings.ToLower(k)] = k
	}
	sort.Strings(keys)
	for _, n := range modelNames {
		if k, ok := lower[n]; ok && scalarText(first[k]) != "" {
			if _, isNum := toNumber(first[k]); !isNum {
				model = k
				break
			}
		}
	}
	for _, n := range scoreNames {
		if k, ok := lower[n]; ok {
			if _, isNum := toNumber(first[k]); isNum {
				score = k
				break
			}
		}
	}
	if score == "" {
		for _, k := range keys {
			if k == model {
				continue
			}
			if _, isNum := toNumber(first[k]); isNum {
				score = k
				break
			}
		}
	}
	return model, score
}

func scalarText(v any) string {
	switch n := v.(type) {
	case string:
		return n
	case json.Number:
		return n.String()
	case float64:
		return strconv.FormatFloat(n, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(n)
	}
	return ""
}

func toNumber(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case string:
		s := strings.TrimSuffix(strings.TrimSpace(n), "%")
		if s == "" {
			return 0, false
		}
		f, err := strconv.ParseFloat(s, 64)
		return f, err == nil
	}
	return 0, false
}

// Probe reads a source once and says what AFK makes of it: the fields it
// uses, how many models the board lists, and which catalog models it
// matched. It is what `afk bench source test` prints.
type Probe struct {
	Rows, Model, Score string
	Listed             int
	Top                []Row
	Matched            map[string]Row // catalog id → its row
}

// ProbeSource fetches and reads one source against the built-in catalog.
func ProbeSource(ctx context.Context, f SourceFetcher, s Source, base []byte) (Probe, error) {
	b, err := f.FetchSource(ctx, s)
	if err != nil {
		return Probe{}, err
	}
	bd, err := ReadBoard(s, b)
	if err != nil {
		return Probe{}, err
	}
	p := Probe{Rows: bd.Rows0, Model: bd.Model, Score: bd.Score, Listed: len(bd.Rows), Matched: map[string]Row{}}
	p.Top = bd.Rows[:min(5, len(bd.Rows))]
	doc, err := decodeObject(base)
	if err == nil {
		cands, _ := doc["candidates"].([]any)
		for _, c := range cands {
			cm, _ := c.(map[string]any)
			if hit := MatchBoard(bd.Rows, candidateNames(cm)...); hit != nil {
				p.Matched[str(cm["id"])] = *hit
			}
		}
	}
	return p, nil
}

// candidateNames are the names a catalog model goes by on a board.
func candidateNames(c map[string]any) []string {
	var out []string
	for _, k := range []string{"arena_match", "models_dev_id", "canonical_model"} {
		if s := str(c[k]); s != "" {
			// "anthropic/claude-opus-5-5" is the model after the slash.
			if i := strings.LastIndexByte(s, '/'); i >= 0 {
				s = s[i+1:]
			}
			out = append(out, s)
		}
	}
	return out
}
