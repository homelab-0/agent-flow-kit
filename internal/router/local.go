package router

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Local models: inference engines running on this machine (Ollama, LM
// Studio, llama.cpp, vLLM, SGLang, ...). Claude Code runs against an
// engine's Anthropic-compatible API (/v1/messages), from a config
// directory of its own, so no plan login is involved and nothing leaves
// this PC. An engine without that API can't run Claude Code and is left
// out.

const (
	// LocalPool is the pool every local model draws on.
	LocalPool = "local"
	// LocalLaunch is the launch class of a local model.
	LocalLaunch = "claude-local"
	// localEstimate is the score of a local model the catalog doesn't know.
	localEstimate = 45.0
)

// LocalEngine is one engine found on this machine.
type LocalEngine struct {
	// Engine is what serves it: ollama, lmstudio, llamacpp, vllm, sglang,
	// localai, mlx, tgi, or "" when it can't tell.
	Engine string   `json:"engine"`
	URL    string   `json:"url"`
	Models []string `json:"models"`
	// State is "idle" or "loaded" when the engine says; "" unknown.
	State string `json:"state,omitempty"`
}

// IsLoopbackURL reports whether u is an http URL on this machine
// (localhost, 127.0.0.0/8 or ::1).
func IsLoopbackURL(u string) bool {
	p, err := url.Parse(u)
	if err != nil || (p.Scheme != "http" && p.Scheme != "https") || p.User != nil {
		return false
	}
	h := p.Hostname()
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// probeLocal looks for an engine at each address, all at once. Only
// loopback addresses are probed; two addresses that reach the same engine
// are kept once.
func probeLocal(ctx context.Context, e ProbeEnv) []LocalEngine {
	if !e.Live || len(e.LocalURLs) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	found := make([]*LocalEngine, len(e.LocalURLs))
	var wg sync.WaitGroup
	seen := map[string]bool{}
	for i, u := range e.LocalURLs {
		base := strings.TrimRight(u, "/")
		if !IsLoopbackURL(base) || seen[base] {
			continue
		}
		seen[base] = true
		wg.Add(1)
		go func() {
			defer wg.Done()
			found[i] = probeEngine(ctx, e.HTTP, base)
		}()
	}
	wg.Wait()
	var out []LocalEngine
	for _, f := range found {
		if f != nil && len(f.Models) > 0 {
			out = append(out, *f)
		}
	}
	return out
}

// probeEngine finds which engine answers at base and the chat models it
// has. Nil when nothing answers there or it has no Anthropic Messages API.
func probeEngine(ctx context.Context, c *http.Client, base string) *LocalEngine {
	// Ollama has its own API, which says which models can call tools
	// (Claude Code needs them) and which are loaded.
	var ver struct {
		Version string `json:"version"`
	}
	if getJSON(ctx, c, base+"/api/version", nil, &ver) && ver.Version != "" {
		if !hasMessages(ctx, c, base) {
			return nil
		}
		return probeOllama(ctx, c, base)
	}
	var list struct {
		Data []struct {
			ID      string `json:"id"`
			OwnedBy string `json:"owned_by"`
		} `json:"data"`
	}
	if !getJSON(ctx, c, base+"/v1/models", nil, &list) || list.Data == nil || !hasMessages(ctx, c, base) {
		return nil
	}
	le := &LocalEngine{URL: base, Models: []string{}}
	for _, m := range list.Data {
		if le.Engine == "" {
			le.Engine = engineFromOwner(m.OwnedBy)
		}
		if okModelName(m.ID) && !reNotChat.MatchString(m.ID) {
			le.Models = append(le.Models, m.ID)
		}
	}
	if le.Engine == "" {
		le.Engine = engineFromProbe(ctx, c, base)
	}
	if le.Engine == "lmstudio" {
		le.Models = lmStudioChat(ctx, c, base, le.Models)
	}
	sort.Strings(le.Models)
	return le
}

// hasMessages reports whether the server has the Anthropic Messages API.
// An empty request is refused as malformed by one that has it, and gets a
// 404 (or 405) from one that doesn't; nothing is generated either way.
func hasMessages(ctx context.Context, c *http.Client, base string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/messages", strings.NewReader("{}"))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	return resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed
}

func probeOllama(ctx context.Context, c *http.Client, base string) *LocalEngine {
	le := &LocalEngine{Engine: "ollama", URL: base, Models: []string{}}
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if !getJSON(ctx, c, base+"/api/tags", nil, &tags) {
		return nil
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, m := range tags.Models {
		if !okModelName(m.Name) {
			continue
		}
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			var show struct {
				Capabilities []string `json:"capabilities"`
			}
			body, _ := json.Marshal(map[string]string{"model": name})
			if getJSON(ctx, c, base+"/api/show", body, &show) && contains(show.Capabilities, "tools") {
				mu.Lock()
				le.Models = append(le.Models, name)
				mu.Unlock()
			}
		}(m.Name)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		var ps struct {
			Models []struct {
				Name string `json:"name"`
			} `json:"models"`
		}
		if getJSON(ctx, c, base+"/api/ps", nil, &ps) {
			mu.Lock()
			le.State = map[bool]string{true: "loaded", false: "idle"}[len(ps.Models) > 0]
			mu.Unlock()
		}
	}()
	wg.Wait()
	sort.Strings(le.Models)
	return le
}

// lmStudioChat keeps the models LM Studio lists as language models (its
// own API says which are embeddings); all of them when it doesn't answer.
func lmStudioChat(ctx context.Context, c *http.Client, base string, models []string) []string {
	var v0 struct {
		Data []struct {
			ID   string `json:"id"`
			Type string `json:"type"`
		} `json:"data"`
	}
	if !getJSON(ctx, c, base+"/api/v0/models", nil, &v0) || v0.Data == nil {
		return models
	}
	llm := map[string]bool{}
	for _, m := range v0.Data {
		if m.Type == "llm" || m.Type == "vlm" {
			llm[m.ID] = true
		}
	}
	var out []string
	for _, m := range models {
		if llm[m] {
			out = append(out, m)
		}
	}
	return out
}

// engineFromOwner reads the engine from a model's owned_by.
func engineFromOwner(o string) string {
	switch strings.ToLower(o) {
	case "vllm":
		return "vllm"
	case "sglang":
		return "sglang"
	case "llamacpp", "llama.cpp":
		return "llamacpp"
	case "organization_owner":
		return "lmstudio"
	case "localai":
		return "localai"
	case "mlx", "mlx-lm":
		return "mlx"
	case "tgi", "text-generation-inference":
		return "tgi"
	}
	return ""
}

// engineFromProbe asks the endpoints only one engine has.
func engineFromProbe(ctx context.Context, c *http.Client, base string) string {
	var any map[string]any
	switch {
	case getJSON(ctx, c, base+"/api/v0/models", nil, &any):
		return "lmstudio"
	case getJSON(ctx, c, base+"/props", nil, &any):
		return "llamacpp"
	case getJSON(ctx, c, base+"/get_server_info", nil, &any):
		return "sglang"
	}
	return ""
}

var reNotChat = regexp.MustCompile(`(?i)embed|rerank|whisper|tts|bge-|e5-`)

func okModelName(n string) bool {
	return n != "" && len(n) <= 120 && !strings.ContainsAny(n, "\x00\n\r\x1b")
}

// getJSON GETs (or, with a body, POSTs) u and decodes a 2xx answer.
func getJSON(ctx context.Context, c *http.Client, u string, body []byte, v any) bool {
	method := http.MethodGet
	var r io.Reader
	if body != nil {
		method, r = http.MethodPost, bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, r)
	if err != nil {
		return false
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return false
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(v) == nil
}

// localPool is the pool of the local engines: available while one
// answers. There is no quota, so it carries no usage figures.
func localPool(found []LocalEngine) Pool {
	p := Pool{PoolID: LocalPool, Provider: "this machine", CostClass: "local", State: "offline", QuotaSource: "local_probe"}
	if len(found) > 0 {
		p.State = "available"
	}
	return p
}

var reModelKey = regexp.MustCompile(`[^a-z0-9]+`)

// modelKey reduces a model name to letters and digits: "qwen3.6:27b",
// "Qwen/Qwen3.6-27B" and "local/qwen3.6-27b" all become "qwen3627b". A
// GGUF file's quantisation suffix is dropped.
func modelKey(s string) string {
	s = strings.ToLower(s)
	if i := strings.LastIndex(s, "/"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.TrimSuffix(s, ".gguf")
	s = strings.TrimSuffix(s, ":latest")
	for i := 0; i < 3; i++ {
		s = reQuant.ReplaceAllString(s, "")
	}
	return reModelKey.ReplaceAllString(s, "")
}

var reQuant = regexp.MustCompile(`[-_.:](q\d[\w]*|iq\d[\w]*|f16|bf16|fp16|fp8|awq|gptq|int4|int8|mlx|gguf|instruct)$`)

// localCandidates are the local engines' models as candidates. A model the
// catalog knows (by its open-weights name) takes the catalog's scores; any
// other is a flat estimate, below every plan model.
func (r *Router) localCandidates(probe *Probe) []Candidate {
	if len(probe.Local) == 0 {
		return nil
	}
	known := map[string]map[string]Benchmark{}
	if r.Catalog != nil {
		for _, c := range r.Catalog.Candidates {
			if c.RequiresGateway || c.ModelFamily == "local-cluster" {
				for _, n := range []string{c.Model, c.CanonicalModel} {
					if k := modelKey(n); k != "" {
						if _, dup := known[k]; !dup {
							known[k] = c.Benchmarks
						}
					}
				}
			}
		}
	}
	free := true
	var out []Candidate
	for _, le := range probe.Local {
		for _, m := range le.Models {
			bm := known[modelKey(m)]
			if bm == nil {
				bm = map[string]Benchmark{}
				for _, tc := range taskClasses {
					bm[tc] = Benchmark{Score: f64(localEstimate), Name: "Local model estimate"}
				}
			}
			out = append(out, Candidate{
				ID: "local-" + le.Engine + "-" + m, Harness: "claude", LaunchClass: LocalLaunch, EntitlementPool: LocalPool,
				CostClass: "local", IsFree: &free, Tier: "local", Model: m, CanonicalModel: le.Engine + "/" + m,
				ModelFamily: "local", SupportedEfforts: []string{}, Benchmarks: bm, engineURL: le.URL,
			})
		}
	}
	return out
}

// localEngineAt is the engine found at u.
func (p *Probe) localEngineAt(u string) (LocalEngine, bool) {
	for _, le := range p.Local {
		if le.URL == u {
			return le, true
		}
	}
	return LocalEngine{}, false
}

// taskClasses are the classes a task is scored on.
var taskClasses = []string{"frontier_synthesis", "architecture", "coding_complex", "coding_standard", "coding_review", "research", "security", "webdev"}

// AllCandidates is every model the router can choose from with this
// probe: the catalog, the models CLIs reported, and the local engines'.
func (r *Router) AllCandidates(allowMetered bool) []Candidate {
	probe := r.Probe
	if probe == nil {
		probe = &Probe{}
	}
	return append(r.candidates(allowMetered), r.localCandidates(probe)...)
}

// EngineURL is the local engine a local candidate runs on.
func (c Candidate) EngineURL() string { return c.engineURL }
