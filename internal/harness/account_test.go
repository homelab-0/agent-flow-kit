package harness

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

func TestParseModelList(t *testing.T) {
	cases := []struct {
		name, format, out string
		want              []string
	}{
		{"codex", "codex-json", `{"models":[{"slug":"gpt-6.2-sol","visibility":"list"},{"slug":"gpt-reserve","visibility":"hide"},{"slug":"gpt-6-astra","visibility":"list"}]}`,
			[]string{"gpt-6.2-sol", "gpt-6-astra"}},
		{"codex not json", "codex-json", "error: not logged in", nil},
		{"grok", "grok-text", "You are not authenticated\nDefault model: grok-4.7\n\nAvailable models:\n* grok-4.7 (default)\n  grok-4.7-build-fast\n  grok-4.6\n  grok-4.5\n",
			[]string{"grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"}},
		{"grok without a list", "grok-text", "Default model: grok-4.7\n", nil},
		{"agy", "tsv", "gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\ngemini-3.8-flash-low\tGemini 3.8 Flash (Low)\nclaude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n",
			[]string{"gemini-4-hydrogen-high", "gemini-3.8-flash-low", "claude-sonnet-4-6"}},
		{"opencode", "lines", "opencode/big-pickle\nopencode/grok-code\n\nopencode/big-pickle\n",
			[]string{"opencode/big-pickle", "opencode/grok-code"}},
		{"a notice is not a model", "lines", "No models available. Sign in first.\n", nil},
	}
	for _, c := range cases {
		if got := ParseModelList(c.format, []byte(c.out)); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestManifestsNameAModelList(t *testing.T) {
	for _, n := range []string{"codex", "grok", "agy", "opencode"} {
		a, ok := Lookup(n)
		if !ok || len(a.Manifest.ModelList.Command) < 2 || a.Manifest.ModelList.Format == "" {
			t.Errorf("%s: no model list command in its manifest", n)
		}
	}
	if a, _ := Lookup("claude"); len(a.Manifest.ModelList.Command) != 0 {
		t.Error("claude lists its models over the control channel; its manifest must not name a command")
	}
}

func TestParseClaudePlan(t *testing.T) {
	out := `{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","planTier":"max_20x","email":"someone@example.com"}`
	if got := ParseClaudePlan([]byte(out)); got != "max_20x" {
		t.Errorf("plan = %q", got)
	}
	if got := ParseClaudePlan([]byte(`{"loggedIn":true,"subscriptionType":"pro"}`)); got != "pro" {
		t.Errorf("plan without a tier = %q", got)
	}
	if got := ParseClaudePlan([]byte("Not logged in")); got != "" {
		t.Errorf("plan from text = %q", got)
	}
}

const codexLimits = `{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1796098672},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"56656.97"}},"accountId":"acct-secret"}`

func TestParseCodexRateLimits(t *testing.T) {
	var rep Account
	ParseCodexRateLimits([]byte(codexLimits), &rep)
	want := []Window{{Minutes: 10080, UsedPct: 30, ResetsAt: 1796098672}}
	if rep.Plan != "pro" || !reflect.DeepEqual(rep.Windows, want) {
		t.Errorf("plan %q windows %+v", rep.Plan, rep.Windows)
	}
	if rep.Extra == nil || !rep.Extra.Enabled || rep.Extra.Unlimited || rep.Extra.Balance != "56656.97" {
		t.Errorf("extra = %+v", rep.Extra)
	}
	var none Account
	ParseCodexRateLimits([]byte(`{"rateLimits":{"primary":null,"secondary":null}}`), &none)
	if len(none.Windows) != 0 || none.Extra != nil {
		t.Errorf("no windows reported, got %+v", none)
	}
}

// stub writes an executable shell script named name into dir.
func stub(t *testing.T, dir, name, body string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestAskCodexUsesTheAppServer(t *testing.T) {
	dir := t.TempDir()
	stub(t, dir, "codex", `[ "$1" = app-server ] || exit 2
while read -r l; do
  case "$l" in
    *'"id":2'*) echo '{"id":2,"result":`+codexLimits+`}' ;;
    *'"id":3'*) echo '{"id":3,"result":{"data":[{"id":"gpt-6.2-sol","model":"gpt-6.2-sol","isDefault":true},{"id":"gpt-reserve","model":"gpt-reserve","hidden":true},{"id":"gpt-6-astra","model":"gpt-6-astra"}]}}' ;;
  esac
done
`)
	rep, ok := Ask(context.Background(), Env{BinDir: dir}, "codex")
	if !ok {
		t.Fatal("codex not found")
	}
	if !rep.ModelsKnown || !reflect.DeepEqual(rep.Models, []string{"gpt-6.2-sol", "gpt-6-astra"}) || rep.DefaultModel != "gpt-6.2-sol" {
		t.Errorf("models = %q (default %q)", rep.Models, rep.DefaultModel)
	}
	if rep.Plan != "pro" || len(rep.Windows) != 1 || rep.Windows[0].UsedPct != 30 || rep.UsageNote != "" {
		t.Errorf("usage = %+v note %q", rep.Windows, rep.UsageNote)
	}
}

func TestAskCodexFallsBackToDebugModels(t *testing.T) {
	dir := t.TempDir()
	stub(t, dir, "codex", `if [ "$1" = debug ]; then echo '{"models":[{"slug":"gpt-6.2-sol","visibility":"list"}]}'; exit 0; fi
exit 1
`)
	rep, _ := Ask(context.Background(), Env{BinDir: dir}, "codex")
	if !reflect.DeepEqual(rep.Models, []string{"gpt-6.2-sol"}) || len(rep.Windows) != 0 || rep.UsageNote == "" {
		t.Errorf("got %+v", rep)
	}
}

func TestAskSaysWhyThereIsNoUsage(t *testing.T) {
	dir := t.TempDir()
	stub(t, dir, "grok", `echo "Available models:"; echo "* grok-4.7 (default)"; echo "  grok-4.6"`)
	stub(t, dir, "agy", `printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n'`)
	// Claude Code answers the plan from a command, and its models over
	// print mode's control channel: a request on stdin, no message.
	stub(t, dir, "claude", `if [ "$1" = auth ]; then
  echo '{"loggedIn":true,"planTier":"max_20x","email":"someone@example.com"}'; exit 0
fi
read -r line
case "$line" in *'"subtype":"list_models"'*) ;; *) exit 3;; esac
if read -r more; then exit 4; fi
echo '{"type":"system","subtype":"hook_started","session_id":"s1"}'
echo '{"type":"control_response","response":{"subtype":"success","response":{"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)"},{"value":"opus","resolvedModel":"claude-opus-5-5"},{"value":"claude-fable-5-2"},{"value":"sonnet","resolvedModel":"claude-sonnet-5-5"}]}}}'`)
	stub(t, dir, "opencode", `exit 1`)
	e := Env{BinDir: dir}
	grok, _ := Ask(context.Background(), e, "grok")
	if !reflect.DeepEqual(grok.Models, []string{"grok-4.7", "grok-4.6"}) || grok.UsageNote == "" || len(grok.Windows) != 0 {
		t.Errorf("grok = %+v", grok)
	}
	agy, _ := Ask(context.Background(), e, "agy")
	if !reflect.DeepEqual(agy.Models, []string{"gemini-4-hydrogen-high"}) || agy.UsageNote == "" {
		t.Errorf("agy = %+v", agy)
	}
	claude, _ := Ask(context.Background(), e, "claude")
	if claude.Plan != "max_20x" || claude.UsageNote == "" {
		t.Errorf("claude = %+v", claude)
	}
	// "default" is what Claude Code picks, not a model of its own.
	if !reflect.DeepEqual(claude.Models, []string{"opus", "claude-fable-5-2", "sonnet"}) || !claude.ModelsKnown || claude.DefaultModel != "claude-opus-5-5" {
		t.Errorf("claude models = %v (known %v, default %q)", claude.Models, claude.ModelsKnown, claude.DefaultModel)
	}
	// A CLI whose list command fails is "unknown", never "no models".
	oc, ok := Ask(context.Background(), e, "opencode")
	if !ok || oc.ModelsKnown || oc.Models != nil || oc.UsageNote == "" {
		t.Errorf("opencode = %+v", oc)
	}
	if _, ok := Ask(context.Background(), e, "pi"); ok {
		t.Error("pi isn't installed here")
	}
}
