package tui

import (
	"slices"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// noBrandLogo are the kinds that publish no mark AFK can ship; they keep
// their text tag.
var noBrandLogo = []string{"tabbyapi", "strata"}

// Every gateway kind and engine AFK knows has a logo on both terminal
// backgrounds, so adding one in Config shows its mark. (Terminals without
// images draw a pixel mark, except for thin marks, which keep their text
// tag there by design.)
func TestBrandLogosCoverEveryGatewayAndEngine(t *testing.T) {
	names := logoNames()
	kinds := append(slices.Clone(config.Gateways), config.Engines...)
	for _, kind := range kinds {
		for _, dark := range []bool{true, false} {
			name := NewTheme(dark).brandLogo(kind)
			if slices.Contains(noBrandLogo, kind) {
				if name != "" {
					t.Errorf("%s is listed as having no logo but maps to %q", kind, name)
				}
				continue
			}
			if !slices.Contains(names, name) {
				t.Errorf("%s (dark=%v): logo %q is not embedded", kind, dark, name)
			}
		}
	}
	for kind := range brandLogos {
		if !slices.Contains(kinds, kind) {
			t.Errorf("logo for %q, which is no gateway kind or engine", kind)
		}
	}
	for kind := range engineCodes {
		if !slices.Contains(config.Engines, kind) {
			t.Errorf("engine code for %q, which config does not know", kind)
		}
	}
}

// A gateway row and an engine draw their own marks, a gateway kind
// without one keeps the GW tag, and single-colour marks follow the background.
func TestBrandLogoCells(t *testing.T) {
	ids := Logos{}
	for i, n := range logoNames() {
		ids[n] = uint32(logoBase + i)
	}
	dark := NewTheme(true).WithLogos(ids)
	light := NewTheme(false).WithLogos(ids)
	gw := func(kind string) engine.Route {
		return engine.Route{LaunchClass: "claude-gateway", GatewayKind: kind}
	}
	if dark.logoName(gw("litellm")) != "litellm" || dark.logoName(gw("kong")) != "kong-light" || light.logoName(gw("kong")) != "kong-dark" {
		t.Error("gateway kinds should map to their logos")
	}
	if dark.logoName(gw("vllm")) != "vllm" || light.logoName(gw("ollama")) != "ollama-dark" {
		t.Error("a gateway whose kind is an engine should use the engine's logo")
	}
	if s := (line{dark.logo(gw("somegateway"))}).plain(); s != "GW" {
		t.Errorf("an unknown gateway kind should keep the GW tag, got %q", s)
	}
	if s := (line{dark.logo(gw(""))}).plain(); s != "GW" {
		t.Errorf("a gateway of no kind should keep the GW tag, got %q", s)
	}
	for _, e := range config.Engines {
		if slices.Contains(noBrandLogo, e) {
			continue
		}
		if s := (line{dark.engineLogo(e)}).plain(); s == engineCodes[e] {
			t.Errorf("%s fell back to its text tag", e)
		}
	}
	if s := (line{dark.engineLogo("someengine")}).plain(); s != "LO" {
		t.Errorf("an unknown engine should read LO, got %q", s)
	}
}
