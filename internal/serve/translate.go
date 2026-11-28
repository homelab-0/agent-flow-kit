package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// A gateway speaks in chat messages; an agent CLI takes one prompt. This
// file is the way in: an OpenAI chat request or an Anthropic messages
// request becomes a conversation, and the conversation becomes a prompt.

// turn is one message of the conversation, as text.
type turn struct {
	role string // system, user, assistant or tool
	text string
}

// request is a call, whichever API it came in through.
type request struct {
	Model  string
	Turns  []turn
	Stream bool
	// Effort is low, medium or high when the caller asked for one.
	Effort string
	// IncludeUsage: an OpenAI stream that wants a last chunk with usage.
	IncludeUsage bool
	// Ignored are the fields the caller sent that a CLI run can't honour,
	// reported back in the X-AFK-Ignored header.
	Ignored []string
}

// badRequest is a request AFK can't run, with the field at fault.
type badRequest struct {
	msg   string
	param string
}

func (e *badRequest) Error() string { return e.msg }

func bad(param, format string, a ...any) error {
	return &badRequest{msg: fmt.Sprintf(format, a...), param: param}
}

// Fields of each API that a headless CLI run has no way to apply. They
// are accepted, so an ordinary client works, and named in X-AFK-Ignored.
var (
	openAIIgnored = []string{"temperature", "top_p", "max_tokens", "max_completion_tokens", "stop", "seed",
		"presence_penalty", "frequency_penalty", "logit_bias", "logprobs", "top_logprobs", "response_format",
		"tools", "functions", "parallel_tool_calls", "user", "metadata", "store", "service_tier", "modalities", "prediction"}
	anthropicIgnored = []string{"temperature", "top_p", "top_k", "max_tokens", "stop_sequences", "tools", "metadata",
		"service_tier", "thinking"}
)

func ignored(raw map[string]json.RawMessage, names []string) []string {
	var out []string
	for _, n := range names {
		if v, ok := raw[n]; ok && string(v) != "null" {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

// parseOpenAI reads a /v1/chat/completions body.
func parseOpenAI(body []byte) (*request, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, bad("", "the body is not a JSON object: %v", err)
	}
	var in struct {
		Model         string      `json:"model"`
		Messages      []oaMessage `json:"messages"`
		Stream        bool        `json:"stream"`
		StreamOptions *struct {
			IncludeUsage bool `json:"include_usage"`
		} `json:"stream_options"`
		N               *int            `json:"n"`
		ToolChoice      json.RawMessage `json:"tool_choice"`
		FunctionCall    json.RawMessage `json:"function_call"`
		ReasoningEffort string          `json:"reasoning_effort"`
	}
	if err := json.Unmarshal(body, &in); err != nil {
		return nil, bad("", "the request doesn't have the shape of a chat completion: %v", err)
	}
	if in.N != nil && *in.N != 1 {
		return nil, bad("n", "AFK gives one answer per request (n must be 1)")
	}
	// The caller's own tools can't be handed to a CLI. Left to choose, the
	// model simply answers in text; told it must call one, it can't.
	if forcesTool(in.ToolChoice) || forcesTool(in.FunctionCall) {
		return nil, bad("tool_choice", "AFK can't make the model call your tools: a call is answered by an agent CLI, which has only its own. Send the request without a forced tool_choice")
	}
	if len(in.Messages) == 0 {
		return nil, bad("messages", "messages is empty")
	}
	req := &request{Model: in.Model, Stream: in.Stream, Effort: effort(in.ReasoningEffort), Ignored: ignored(raw, openAIIgnored)}
	req.IncludeUsage = in.StreamOptions != nil && in.StreamOptions.IncludeUsage
	for i, m := range in.Messages {
		t, err := m.turn(i)
		if err != nil {
			return nil, err
		}
		req.Turns = append(req.Turns, t)
	}
	return req, nil
}

// forcesTool reports whether a tool_choice demands a tool call: anything
// but none and auto.
func forcesTool(v json.RawMessage) bool {
	s := strings.TrimSpace(string(v))
	switch s {
	case "", "null", `"none"`, `"auto"`:
		return false
	}
	var obj struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(v, &obj) == nil && (obj.Type == "auto" || obj.Type == "none") {
		return false
	}
	return true
}

// effort maps a caller's reasoning effort to the three levels every CLI
// that has effort takes. Anything else leaves the CLI's own default.
func effort(s string) string {
	switch strings.ToLower(s) {
	case "minimal", "low":
		return "low"
	case "medium":
		return "medium"
	case "high", "xhigh", "max":
		return "high"
	}
	return ""
}

type oaMessage struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	Name       string          `json:"name"`
	ToolCallID string          `json:"tool_call_id"`
	ToolCalls  []struct {
		Function struct {
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"function"`
	} `json:"tool_calls"`
}

func (m oaMessage) turn(i int) (turn, error) {
	param := fmt.Sprintf("messages[%d]", i)
	role := m.Role
	switch role {
	case "developer":
		role = "system"
	case "function":
		role = "tool"
	case "system", "user", "assistant", "tool":
	default:
		return turn{}, bad(param+".role", "%q is not a message role", m.Role)
	}
	text, err := contentText(m.Content, param+".content")
	if err != nil {
		return turn{}, err
	}
	var b strings.Builder
	b.WriteString(text)
	for _, c := range m.ToolCalls {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "(called the tool %s with %s)", c.Function.Name, c.Function.Arguments)
	}
	return turn{role: role, text: b.String()}, nil
}

// contentText reads a message's content: a string, or a list of parts.
// Only text can go into a prompt; an image or a file is refused, rather
// than dropped and answered as if it had been seen.
func contentText(raw json.RawMessage, param string) (string, error) {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return "", nil
	}
	if s[0] == '"' {
		var out string
		if err := json.Unmarshal(raw, &out); err != nil {
			return "", bad(param, "the content is not a string: %v", err)
		}
		return out, nil
	}
	var parts []struct {
		Type    string          `json:"type"`
		Text    string          `json:"text"`
		Refusal string          `json:"refusal"`
		Name    string          `json:"name"`
		Input   json.RawMessage `json:"input"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return "", bad(param, "the content is neither a string nor a list of parts")
	}
	var out []string
	for j, p := range parts {
		switch p.Type {
		case "text", "input_text", "output_text":
			out = append(out, p.Text)
		case "refusal":
			out = append(out, p.Refusal)
		case "thinking", "redacted_thinking":
			// The model's earlier reasoning is not part of what was said.
		case "tool_use":
			out = append(out, fmt.Sprintf("(called the tool %s with %s)", p.Name, string(p.Input)))
		case "tool_result":
			inner, err := contentText(p.Content, fmt.Sprintf("%s[%d].content", param, j))
			if err != nil {
				return "", err
			}
			out = append(out, "(tool result) "+inner)
		default:
			return "", bad(fmt.Sprintf("%s[%d].type", param, j), "AFK takes text only: a %q part can't be passed to an agent CLI", p.Type)
		}
	}
	return strings.Join(out, "\n"), nil
}

// parseAnthropic reads a /v1/messages body.
func parseAnthropic(body []byte) (*request, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, bad("", "the body is not a JSON object: %v", err)
	}
	var in struct {
		Model    string          `json:"model"`
		System   json.RawMessage `json:"system"`
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
		Stream       bool            `json:"stream"`
		ToolChoice   json.RawMessage `json:"tool_choice"`
		OutputConfig *struct {
			Effort string `json:"effort"`
		} `json:"output_config"`
	}
	if err := json.Unmarshal(body, &in); err != nil {
		return nil, bad("", "the request doesn't have the shape of a messages request: %v", err)
	}
	if forcesTool(in.ToolChoice) {
		return nil, bad("tool_choice", "AFK can't make the model call your tools: a call is answered by an agent CLI, which has only its own. Send the request without a forced tool_choice")
	}
	if len(in.Messages) == 0 {
		return nil, bad("messages", "messages is empty")
	}
	req := &request{Model: in.Model, Stream: in.Stream, Ignored: ignored(raw, anthropicIgnored)}
	if in.OutputConfig != nil {
		req.Effort = effort(in.OutputConfig.Effort)
	}
	sys, err := contentText(in.System, "system")
	if err != nil {
		return nil, err
	}
	if sys != "" {
		req.Turns = append(req.Turns, turn{role: "system", text: sys})
	}
	for i, m := range in.Messages {
		param := fmt.Sprintf("messages[%d]", i)
		if m.Role != "user" && m.Role != "assistant" {
			return nil, bad(param+".role", "%q is not a message role", m.Role)
		}
		text, err := contentText(m.Content, param+".content")
		if err != nil {
			return nil, err
		}
		req.Turns = append(req.Turns, turn{role: m.Role, text: text})
	}
	return req, nil
}

// errNoPrompt is a conversation with nothing in it to answer.
var errNoPrompt = errors.New("the messages carry no text to answer")

// prompt writes the conversation as the one prompt a CLI takes.
//
// A single user message is passed as it is. Anything more is laid out so
// the model can tell the caller's instructions, the earlier turns and the
// message to answer apart. Each call is a new CLI session: the caller
// sends the whole conversation every time, as the chat APIs expect, and
// AFK keeps none of it.
func prompt(turns []turn) (string, error) {
	var system []string
	var talk []turn
	for _, t := range turns {
		if strings.TrimSpace(t.text) == "" {
			continue
		}
		if t.role == "system" {
			system = append(system, strings.TrimSpace(t.text))
			continue
		}
		talk = append(talk, turn{t.role, strings.TrimSpace(t.text)})
	}
	if len(talk) == 0 {
		return "", errNoPrompt
	}
	last := talk[len(talk)-1]
	if len(system) == 0 && len(talk) == 1 && last.role == "user" {
		return last.text, nil
	}
	var b strings.Builder
	if len(system) > 0 {
		b.WriteString("Instructions for this conversation:\n\n")
		b.WriteString(strings.Join(system, "\n\n"))
		b.WriteString("\n\n")
	}
	earlier := talk
	if last.role == "user" {
		earlier = talk[:len(talk)-1]
	}
	if len(earlier) > 0 {
		b.WriteString("The conversation so far, oldest first:\n")
		for _, t := range earlier {
			b.WriteString("\n[" + speaker(t.role) + "]\n" + t.text + "\n")
		}
		b.WriteString("\n")
	}
	if last.role == "user" {
		if len(earlier) > 0 {
			b.WriteString("Answer this next message from the user:\n\n")
		} else {
			b.WriteString("The user's message:\n\n")
		}
		b.WriteString(last.text)
	} else {
		b.WriteString("Carry on from there with the assistant's next reply.")
	}
	return b.String(), nil
}

func speaker(role string) string {
	switch role {
	case "assistant":
		return "Assistant"
	case "tool":
		return "Tool result"
	}
	return "User"
}
