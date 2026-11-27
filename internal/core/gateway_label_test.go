package core

import (
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/router"
)

func TestLabelGateway(t *testing.T) {
	u := "http://factory:4000"
	st := &state{settings: Settings{GatewayURL: u, GatewayName: "default", Gateways: map[string]config.Gateway{
		"agentgateway": {Kind: "agentgateway", URL: u + "/", Engine: "vllm", Host: "factory"},
	}}}
	r := router.Route{LaunchClass: "claude-gateway", LitellmBaseURL: &u}
	st.labelGateway(&r)
	if r.GatewayName != "agentgateway" || r.GatewayKind != "agentgateway" || r.Engine != "vllm" || r.EngineHost != "factory" {
		t.Errorf("config gateway: %+v", r)
	}
	st.settings.Gateways = nil
	r = router.Route{LaunchClass: "claude-gateway", LitellmBaseURL: &u}
	st.labelGateway(&r)
	if r.GatewayName != "default" || r.Engine != "" {
		t.Errorf("environment gateway: %+v", r)
	}
	plan := router.Route{LaunchClass: "claude-plan"}
	st.labelGateway(&plan)
	if plan.GatewayName != "" {
		t.Error("a plan route has no gateway")
	}
}
