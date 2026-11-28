package serve

import (
	"strings"
	"testing"
)

func TestPromptLayout(t *testing.T) {
	one, err := prompt([]turn{{"user", "  what is 2+2?  "}})
	if err != nil || one != "what is 2+2?" {
		t.Errorf("a single message should pass as it is: %q %v", one, err)
	}
	got, err := prompt([]turn{
		{"system", "Answer in French."}, {"user", "hi"}, {"assistant", "salut"}, {"tool", "42"}, {"user", "and now?"},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `Instructions for this conversation:

Answer in French.

The conversation so far, oldest first:

[User]
hi

[Assistant]
salut

[Tool result]
42

Answer this next message from the user:

and now?`
	if got != want {
		t.Errorf("got:\n%s\n\nwant:\n%s", got, want)
	}
	tail, _ := prompt([]turn{{"user", "write a poem"}, {"assistant", "Roses are"}})
	if !strings.HasSuffix(tail, "Carry on from there with the assistant's next reply.") {
		t.Errorf("%q", tail)
	}
	if _, err := prompt([]turn{{"system", "x"}, {"user", "  "}}); err == nil {
		t.Error("nothing to answer should be an error")
	}
}

func TestParseOpenAI(t *testing.T) {
	req, err := parseOpenAI([]byte(`{"model":"afk/auto","stream":true,"reasoning_effort":"minimal","max_tokens":5,"tools":[{}],"tool_choice":"auto",
		"messages":[{"role":"developer","content":"d"},{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]},
		{"role":"assistant","content":null,"tool_calls":[{"function":{"name":"f","arguments":"{}"}}]},{"role":"tool","tool_call_id":"1","content":"r"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if !req.Stream || req.Effort != "low" || strings.Join(req.Ignored, ",") != "max_tokens,tools" {
		t.Errorf("%+v", req)
	}
	if len(req.Turns) != 4 || req.Turns[0].role != "system" || req.Turns[1].text != "a\nb" || !strings.Contains(req.Turns[2].text, "called the tool f") || req.Turns[3].role != "tool" {
		t.Errorf("turns %+v", req.Turns)
	}
	for _, body := range []string{
		`{"model":"m","messages":[{"role":"robot","content":"x"}]}`,
		`{"model":"m","tool_choice":{"type":"function","function":{"name":"f"}},"messages":[{"role":"user","content":"x"}]}`,
		`{"model":"m","messages":[{"role":"user","content":[{"type":"input_audio"}]}]}`,
	} {
		if _, err := parseOpenAI([]byte(body)); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
}

func TestParseAnthropic(t *testing.T) {
	req, err := parseAnthropic([]byte(`{"model":"claude/sonnet","max_tokens":10,"system":[{"type":"text","text":"s"}],"tool_choice":{"type":"auto"},
		"messages":[{"role":"user","content":"q"},{"role":"assistant","content":[{"type":"thinking","thinking":"t"},{"type":"text","text":"a"},{"type":"tool_use","name":"f","input":{"x":1}}]},
		{"role":"user","content":[{"type":"tool_result","tool_use_id":"1","content":[{"type":"text","text":"r"}]}]}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(req.Turns) != 4 || req.Turns[0] != (turn{"system", "s"}) || !strings.Contains(req.Turns[2].text, `called the tool f with {"x":1}`) || req.Turns[3].text != "(tool result) r" {
		t.Errorf("turns %+v", req.Turns)
	}
	if strings.Contains(req.Turns[2].text, "thinking") {
		t.Error("earlier reasoning went into the prompt")
	}
	for _, body := range []string{
		`{"model":"m","messages":[{"role":"user","content":[{"type":"image","source":{}}]}]}`,
		`{"model":"m","tool_choice":{"type":"any"},"messages":[{"role":"user","content":"x"}]}`,
		`{"model":"m","messages":[{"role":"system","content":"x"}]}`,
	} {
		if _, err := parseAnthropic([]byte(body)); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
}

func TestCodexItems(t *testing.T) {
	d := &decoder{format: "codex-items"}
	out := ""
	for _, l := range []string{
		`{"type":"thread.started","thread_id":"t1"}`,
		`{"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"First."}}`,
		`{"type":"item.completed","item":{"type":"command_execution","text":"ls"}}`,
		`{"type":"item.completed","item":{"type":"agent_message","text":"Second."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":40,"output_tokens":5}}`,
		`not json`,
	} {
		out += d.line([]byte(l))
	}
	if out != "First.\n\nSecond." || d.usage == nil || *d.usage != (Usage{Input: 50, Output: 5}) {
		t.Errorf("%q %+v", out, d.usage)
	}
}
