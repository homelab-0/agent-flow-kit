package harness

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const agyUsageOut = `{"conversation_id":"","status":"SUCCESS","response":"...","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-12-05T09:24:14Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},{"id":"3p-5h","window":"5h","remaining_fraction":0.4,"reset_time":"1970-01-01T00:00:00Z"}]}]}}}`

func TestParseAgyUsage(t *testing.T) {
	w, spent, ok := ParseAgyUsage([]byte(agyUsageOut))
	if !ok || spent || len(w) != 3 {
		t.Fatalf("windows %+v spent %v ok %v", w, spent, ok)
	}
	if w[0].Scope != "Gemini Models" || w[0].Minutes != 10080 || w[0].UsedPct != 25 || w[0].ResetsAt != time.Date(2026, 12, 5, 9, 24, 14, 0, time.UTC).Unix() {
		t.Errorf("gemini weekly = %+v", w[0])
	}
	// 1970 is agy's "not started": no reset time, never a past one.
	if w[2].Minutes != 300 || w[2].UsedPct != 60 || w[2].ResetsAt != 0 || w[1].ResetsAt != 0 {
		t.Errorf("third party = %+v %+v", w[1], w[2])
	}
	// Any sign of a turn means agy took /usage for a prompt.
	for _, out := range []string{
		`{"conversation_id":"c1","num_turns":0,"command":{"name":"usage"}}`,
		`{"conversation_id":"","num_turns":1,"response":"Here is how to check usage"}`,
		`{"num_turns":0,"usage":{"total_tokens":12}}`,
	} {
		if w, spent, ok := ParseAgyUsage([]byte(out)); !spent || ok || w != nil {
			t.Errorf("%s: windows %v spent %v ok %v", out, w, spent, ok)
		}
	}
	if _, spent, ok := ParseAgyUsage([]byte(`{"status":"SUCCESS","num_turns":0}`)); spent || ok {
		t.Error("an answer with no usage command is neither")
	}
}

// agyStub is an agy that logs each call and answers /usage with body.
func agyStub(t *testing.T, dir, version, usage string) string {
	t.Helper()
	log := filepath.Join(dir, "calls")
	stub(t, dir, "agy", `echo "$*" >> "`+log+`"
case "$1" in
--version) echo "`+version+`";;
models) printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n';;
-p) [ "$AGY_CLI_DISABLE_AUTO_UPDATE" = true ] || exit 9
    cat <<'JSON'
`+usage+`
JSON
;;
esac`)
	return log
}

func TestAgyReportsUsageWithoutATurn(t *testing.T) {
	dir := t.TempDir()
	log := agyStub(t, dir, "agy 1.5.19", agyUsageOut)
	rep, ok := Ask(context.Background(), Env{BinDir: dir}, "agy")
	if !ok || len(rep.Windows) != 3 || rep.UsageNote != "" || rep.UsageCommandSpent || !rep.ModelsKnown {
		t.Fatalf("agy = %+v", rep)
	}
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "-p /usage --output-format json --print-timeout 20s") {
		t.Errorf("calls:\n%s", calls)
	}
}

func TestAgyThatAnswersUsageAsAPromptIsNotAskedAgain(t *testing.T) {
	dir := t.TempDir()
	log := agyStub(t, dir, "1.5.19", `{"conversation_id":"c1","num_turns":1,"response":"..."}`)
	e := Env{BinDir: dir}
	rep, _ := Ask(context.Background(), e, "agy")
	if !rep.UsageCommandSpent || len(rep.Windows) != 0 || !strings.Contains(rep.UsageNote, "stopped") {
		t.Fatalf("agy = %+v", rep)
	}
	// The next report is told so, and never runs the command.
	if err := os.Remove(log); err != nil {
		t.Fatal(err)
	}
	rep, _ = AskWith(context.Background(), e, "agy", AskOptions{NoUsageCommand: true})
	calls, _ := os.ReadFile(log)
	if strings.Contains(string(calls), "/usage") || !rep.UsageCommandSpent || len(rep.Windows) != 0 || !rep.ModelsKnown {
		t.Errorf("agy = %+v, calls:\n%s", rep, calls)
	}
}

func TestAnOldAgyIsNotAskedForUsage(t *testing.T) {
	dir := t.TempDir()
	log := agyStub(t, dir, "agy 1.1.10", agyUsageOut)
	rep, _ := Ask(context.Background(), Env{BinDir: dir}, "agy")
	calls, _ := os.ReadFile(log)
	if strings.Contains(string(calls), "/usage") || len(rep.Windows) != 0 || !strings.Contains(rep.UsageNote, "too old") {
		t.Errorf("agy = %+v, calls:\n%s", rep, calls)
	}
}
