package router

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeOllama answers like Ollama: two chat models that call tools, one
// embedding model, and the Messages API.
func fakeOllama(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/version":
			io.WriteString(w, `{"version":"0.14.2"}`)
		case "/api/tags":
			io.WriteString(w, `{"models":[{"name":"qwen3.6:27b"},{"name":"nomic-embed-text:latest"},{"name":"tinyllama:latest"},{"name":"gpt-oss:20b"}]}`)
		case "/api/show":
			var b struct{ Model string }
			_ = json.NewDecoder(r.Body).Decode(&b)
			switch b.Model {
			case "qwen3.6:27b", "gpt-oss:20b":
				io.WriteString(w, `{"capabilities":["completion","tools"]}`)
			case "tinyllama:latest":
				io.WriteString(w, `{"capabilities":["completion"]}`)
			default:
				io.WriteString(w, `{"capabilities":["embedding"]}`)
			}
		case "/api/ps":
			io.WriteString(w, `{"models":[]}`)
		case "/v1/messages":
			w.WriteHeader(http.StatusBadRequest)
		default:
			http.NotFound(w, r)
		}
	}))
}

// fakeOpenAI answers like an OpenAI-compatible engine; messages says
// whether it has the Anthropic Messages API.
func fakeOpenAI(t *testing.T, owner string, messages bool, models ...string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/models":
			var data []map[string]string
			for _, m := range models {
				data = append(data, map[string]string{"id": m, "owned_by": owner})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"data": data})
		case "/v1/messages":
			if !messages {
				http.NotFound(w, r)
				return
			}
			w.WriteHeader(http.StatusBadRequest)
		case "/props":
			io.WriteString(w, `{"model_path":"x"}`)
		default:
			http.NotFound(w, r)
		}
	}))
}

func TestProbeLocalFindsEngines(t *testing.T) {
	ol := fakeOllama(t)
	defer ol.Close()
	vl := fakeOpenAI(t, "vllm", true, "Qwen/Qwen3.6-27B", "BAAI/bge-reranker")
	defer vl.Close()
	lc := fakeOpenAI(t, "", true, "gemma-4-12b-Q4_K_M.gguf")
	defer lc.Close()
	old := fakeOpenAI(t, "vllm", false, "some-model")
	defer old.Close()
	st := fakeOpenAI(t, "strata", false, "glm52")
	defer st.Close()
	got, noAPI := probeLocal(context.Background(), ProbeEnv{
		Live: true, HTTP: http.DefaultClient,
		LocalURLs: []string{ol.URL, vl.URL + "/", lc.URL, old.URL, st.URL, "http://127.0.0.1:1", "http://10.0.0.5:11434", ol.URL},
	})
	// Engines without the Anthropic Messages API are kept apart: shown,
	// never routed to.
	if len(noAPI) != 2 || noAPI[0].Engine != "vllm" || noAPI[1].Engine != "strata" || noAPI[1].URL != st.URL {
		t.Errorf("engines without the Messages API: %+v", noAPI)
	}
	if len(got) != 3 {
		t.Fatalf("found %d engines, want 3: %+v", len(got), got)
	}
	want := []struct{ engine, models, state string }{
		{"ollama", "gpt-oss:20b,qwen3.6:27b", "idle"},
		{"vllm", "Qwen/Qwen3.6-27B", ""},
		{"llamacpp", "gemma-4-12b-Q4_K_M.gguf", ""},
	}
	for i, w := range want {
		if got[i].Engine != w.engine || strings.Join(got[i].Models, ",") != w.models || got[i].State != w.state {
			t.Errorf("engine %d = %+v, want %+v", i, got[i], w)
		}
	}
	if got[1].URL != vl.URL {
		t.Errorf("url %q kept its slash", got[1].URL)
	}
	if u, n := probeLocal(context.Background(), ProbeEnv{Live: false, HTTP: http.DefaultClient, LocalURLs: []string{ol.URL}}); u != nil || n != nil {
		t.Error("probed while not live")
	}
}

func TestModelKey(t *testing.T) {
	for _, n := range []string{"qwen3.6:27b", "Qwen/Qwen3.6-27B", "local/qwen3.6-27b", "qwen3.6-27b-instruct-q4_K_M.gguf", "Qwen3.6-27B-Instruct-AWQ"} {
		if k := modelKey(n); k != "qwen3627b" {
			t.Errorf("modelKey(%q) = %q", n, k)
		}
	}
}

func TestLocalRoutes(t *testing.T) {
	probe := &Probe{
		Harnesses: map[string]HarnessState{"claude": {Installed: true}},
		Pools:     map[string]Pool{LocalPool: localPool([]LocalEngine{{}})},
		Local: []LocalEngine{
			{Engine: "ollama", URL: "http://127.0.0.1:11434", Models: []string{"qwen3.6:27b", "mystery:7b"}, State: "idle"},
			{Engine: "lmstudio", URL: "http://127.0.0.1:1234", Models: []string{"mystery-7b"}},
		},
		LocalGPU: "RTX 5090",
	}
	r := &Router{Catalog: DefaultCatalog(), Probe: probe}
	stage, risk, _ := TaskRoute("coding", "balanced")
	rt := r.Select(Input{Stage: stage, Risk: risk, Surfaces: []string{"code"}, OnlyPool: LocalPool, OnlyEngineURL: "http://127.0.0.1:11434"})
	if rt.IsFallback() {
		t.Fatal("no local route")
	}
	if rt.LaunchClass != LocalLaunch || rt.Model != "qwen3.6:27b" || rt.Engine != "ollama" || rt.EngineGPU != "RTX 5090" ||
		rt.EngineState != "idle" || rt.EngineURL == nil || *rt.EngineURL != "http://127.0.0.1:11434" || rt.Effort != "" || rt.CostClass != "local" {
		t.Errorf("local route = %+v", rt)
	}
	if rt.BenchmarkScore == localEstimate {
		t.Error("a model the catalog knows should take the catalog's score")
	}
	rt = r.Select(Input{Stage: stage, Risk: risk, Surfaces: []string{"code"}, OnlyEngineURL: "http://127.0.0.1:1234"})
	if rt.Model != "mystery-7b" || rt.Engine != "lmstudio" || rt.BenchmarkScore != localEstimate || rt.BenchmarkBasis != "estimate" {
		t.Errorf("unknown model route = %+v", rt)
	}
	rt = r.Select(Input{Stage: stage, Risk: risk, Surfaces: []string{"code"}, ExcludePools: []string{LocalPool}})
	if rt.LaunchClass == LocalLaunch {
		t.Error("ExcludePools kept a local route")
	}
	// No local model reviews work that may merge unattended.
	rs, rr, _ := TaskRoute("review", "balanced")
	if rt := r.Select(Input{Stage: rs, Risk: rr, Surfaces: []string{"code"}, OnlyPool: LocalPool}); !rt.IsFallback() {
		t.Errorf("a local model reviewed: %+v", rt)
	}
}

func TestIsLoopbackURL(t *testing.T) {
	for u, want := range map[string]bool{
		"http://127.0.0.1:11434": true, "http://localhost:1234": true, "http://[::1]:8080": true, "https://127.0.0.2": true,
		"http://10.0.0.5:11434": false, "http://user:pw@127.0.0.1:1": false, "file:///tmp": false, "http://localhost.evil.com": false,
	} {
		if IsLoopbackURL(u) != want {
			t.Errorf("IsLoopbackURL(%q) != %v", u, want)
		}
	}
}

// The owned_by each engine's own server code sends.
func TestEngineFromOwner(t *testing.T) {
	for owner, want := range map[string]string{
		"vllm": "vllm", "koboldcpp": "koboldcpp", "xinference": "xinference", "lmdeploy": "lmdeploy",
		"tabbyAPI": "tabbyapi", "docker": "docker", "lemonade": "lemonade", "strata": "strata",
		"local": "", "openai": "",
	} {
		if got := engineFromOwner(owner); got != want {
			t.Errorf("engineFromOwner(%q) = %q, want %q", owner, got, want)
		}
	}
}
