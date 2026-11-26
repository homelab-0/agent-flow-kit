package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
)

type planCase struct {
	Name   string          `json:"name"`
	Route  json.RawMessage `json:"route"`
	Mode   string          `json:"mode"`
	Yolo   bool            `json:"yolo"`
	Pass   []string        `json:"pass"`
	Prompt string          `json:"prompt"`
	Want   struct {
		OK       bool              `json:"ok"`
		Error    string            `json:"error"`
		Argv     []string          `json:"argv"`
		EnvSet   map[string]string `json:"env_set"`
		EnvFrom  map[string]string `json:"env_from"`
		EnvUnset []string          `json:"env_unset"`
		Answer   json.RawMessage   `json:"answer"`
	} `json:"want"`
}

func testCore(t *testing.T) (*Core, string) {
	t.Helper()
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"claude", "codex", "opencode", "grok", "agy", "pi"} {
		if err := os.WriteFile(filepath.Join(bin, h), []byte("#!/bin/sh\necho 1.0.0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := map[string]string{"AFK_GATEWAY_KEY": "k"}
	return &Core{
		Home: home, Getenv: func(k string) string { return env[k] }, Cwd: home,
		Harness: harness.Env{Home: home, Path: bin, BinDir: bin, OS: runtime.GOOS, Getenv: func(string) string { return "" }},
		Environ: func() []string { return []string{"PATH=/usr/bin", "CLAUDE_CODE_SOMETHING=x"} },
	}, bin
}

// TestLaunchPlansMatchBash compares every plan with what the bash engine's
// agent --launch-plan printed for the same route (testdata/plans.json, a
// frozen fixture: the bash engine was removed after the legacy-bash-final
// tag).
func TestLaunchPlansMatchBash(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	b, err := os.ReadFile("testdata/plans.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []planCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	c, bin := testCore(t)
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			var r engine.Route
			if err := json.Unmarshal(tc.Route, &r); err != nil {
				t.Fatal(err)
			}
			perm := "ask"
			if tc.Yolo {
				perm = "yolo"
			}
			p, err := c.LaunchPlan(context.Background(), r, tc.Mode, perm, tc.Pass, tc.Prompt)
			if !tc.Want.OK {
				var pe *engine.PlanError
				if !errors.As(err, &pe) || pe.Reason != tc.Want.Error {
					t.Fatalf("got %v, want refusal %q", err, tc.Want.Error)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			cx := ""
			var ans struct {
				File string `json:"file"`
			}
			_ = json.Unmarshal(p.Answer, &ans)
			if ans.File != "" {
				cx = ans.File
				defer os.Remove(cx)
			}
			norm := func(s string) string {
				s = strings.ReplaceAll(s, bin+"/", "$BIN/")
				if cx != "" {
					s = strings.ReplaceAll(s, cx, "$CXOUT")
				}
				return strings.ReplaceAll(s, c.Home, "$HOME")
			}
			var argv []string
			for _, a := range p.Argv {
				argv = append(argv, norm(a))
			}
			if !reflect.DeepEqual(argv, tc.Want.Argv) {
				t.Errorf("argv\n got  %q\n want %q", argv, tc.Want.Argv)
			}
			set := map[string]string{}
			for k, v := range p.EnvSet {
				set[k] = norm(v)
			}
			if !reflect.DeepEqual(set, tc.Want.EnvSet) || !reflect.DeepEqual(p.EnvFrom, tc.Want.EnvFrom) {
				t.Errorf("env\n got  %v %v\n want %v %v", set, p.EnvFrom, tc.Want.EnvSet, tc.Want.EnvFrom)
			}
			unset := append([]string(nil), p.EnvUnset...)
			sort.Strings(unset)
			want := tc.Want.EnvUnset
			if strings.HasSuffix(r.LaunchClass, "-gateway") {
				// The engine also unsets the Claude variables of this
				// environment; the bash run had none.
				want = append(append([]string(nil), want...), "CLAUDE_CODE_SOMETHING")
				sort.Strings(want)
			}
			if !(len(unset) == 0 && len(want) == 0) && !reflect.DeepEqual(unset, want) {
				t.Errorf("env_unset\n got  %v\n want %v", unset, want)
			}
			gotAns := norm(string(p.Answer))
			var g, w any
			_ = json.Unmarshal([]byte(gotAns), &g)
			_ = json.Unmarshal(tc.Want.Answer, &w)
			if !reflect.DeepEqual(g, w) {
				t.Errorf("answer %s, want %s", gotAns, tc.Want.Answer)
			}
		})
	}
}

func TestGatewayPlanNeedsAKeyFromAPlainVariable(t *testing.T) {
	c, _ := testCore(t)
	r := engine.Route{Harness: "claude", Model: "q", EntitlementPool: "litellm-local", CostClass: "free", LaunchClass: "claude-gateway", LitellmBaseURL: "http://gw"}
	for env, want := range map[string]string{
		"ANTHROPIC_API_KEY": "AFK_GATEWAY_KEY_ENV must name a plain variable",
		"MY_KEY":            "the gateway needs its key in $MY_KEY",
	} {
		c.Getenv = func(k string) string {
			if k == "AFK_GATEWAY_KEY_ENV" {
				return env
			}
			return ""
		}
		_, err := c.LaunchPlan(context.Background(), r, "interactive", "", nil, "")
		var pe *engine.PlanError
		if !errors.As(err, &pe) || !strings.HasPrefix(pe.Reason, want) {
			t.Errorf("%s: %v", env, err)
		}
	}
}

// A gateway's key goes only to that gateway's own url.
func TestGatewayKeyIsBoundToItsGateway(t *testing.T) {
	c, _ := testCore(t)
	env := map[string]string{"WORK_KEY": "w", "HOME_KEY": "h", "AFK_GATEWAY_KEY": "legacy"}
	c.Getenv = func(k string) string { return env[k] }
	cfg := filepath.Join(c.Home, ".config", "afk", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(body string) {
		if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("version = 1\n[gateway.work]\nurl = \"https://work.example/\"\nkey = \"env:WORK_KEY\"\ndefault = true\n[gateway.home]\nurl = \"http://home.local:4000\"\nkey = \"env:HOME_KEY\"\n")
	route := func(u string) engine.Route {
		return engine.Route{Harness: "claude", Model: "q", EntitlementPool: "litellm-local", CostClass: "free", LaunchClass: "claude-gateway", LitellmBaseURL: u}
	}
	plan := func(u string) (*engine.LaunchPlan, error) {
		return c.LaunchPlan(context.Background(), route(u), "interactive", "", nil, "")
	}
	for u, want := range map[string]string{"https://work.example": "WORK_KEY", "http://home.local:4000/": "HOME_KEY"} {
		p, err := plan(u)
		if err != nil || p.EnvFrom["ANTHROPIC_AUTH_TOKEN"] != want || p.EnvSet["ANTHROPIC_BASE_URL"] != u {
			t.Fatalf("%s: %+v %v", u, p, err)
		}
	}
	// A route to a url no config.toml gateway declares (made before the
	// config changed) is refused, naming both, instead of getting a key.
	_, err := plan("http://u:pw@stale.example")
	var pe *engine.PlanError
	if !errors.As(err, &pe) || !strings.Contains(pe.Reason, "http://stale.example") || !strings.Contains(pe.Reason, "work = https://work.example/") || strings.Contains(pe.Reason, "pw") {
		t.Fatalf("stale route: %v", err)
	}
	// The address from AFK_LITELLM_BASE_URL keeps AFK_GATEWAY_KEY.
	env["AFK_LITELLM_BASE_URL"] = "http://env.local"
	if p, err := plan("http://env.local"); err != nil || p.EnvFrom["ANTHROPIC_AUTH_TOKEN"] != "AFK_GATEWAY_KEY" {
		t.Fatalf("env gateway: %+v %v", p, err)
	}
	// AFK_GATEWAY_KEY_ENV is the explicit override.
	env["AFK_GATEWAY_KEY_ENV"] = "HOME_KEY"
	if p, err := plan("https://work.example"); err != nil || p.EnvFrom["ANTHROPIC_AUTH_TOKEN"] != "HOME_KEY" {
		t.Fatalf("override: %+v %v", p, err)
	}
	delete(env, "AFK_GATEWAY_KEY_ENV")
	// A config.toml that doesn't validate refuses the launch, rather than
	// falling back to AFK_GATEWAY_KEY.
	write("version = 1\n[route]\nprefer = \"fastest\"\n")
	if _, err := plan("http://env.local"); err == nil || !strings.Contains(err.Error(), "route.prefer") {
		t.Fatalf("invalid config: %v", err)
	}
}
