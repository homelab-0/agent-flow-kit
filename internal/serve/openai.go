package serve

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"time"
)

// openAI is the chat completions API.
type openAI struct{}

func (openAI) parse(body []byte) (*request, error) { return parseOpenAI(body) }

// openAITypes are the error types OpenAI clients know.
var openAITypes = map[string]string{
	KindInvalid: "invalid_request_error", KindNotFound: "invalid_request_error", KindTooLarge: "invalid_request_error",
	KindAuth: "authentication_error", KindPermission: "permission_error", KindRateLimit: "rate_limit_error",
	KindOverloaded: "server_error", KindUpstream: "server_error",
}

var openAICodes = map[string]string{
	KindNotFound: "model_not_found", KindAuth: "invalid_api_key", KindRateLimit: "rate_limit_exceeded",
	KindTooLarge: "context_length_exceeded",
}

func openAIError(o Outcome) map[string]any {
	var code any
	if c := openAICodes[o.Kind]; c != "" {
		code = c
	}
	return map[string]any{"error": map[string]any{"message": o.Error, "type": openAITypes[o.Kind], "param": nil, "code": code}}
}

func (openAI) fail(w http.ResponseWriter, o Outcome) {
	retryAfter(w, o)
	writeJSON(w, o.Status, openAIError(o))
}

// openAIUsage is the usage object, or nil when the CLI reported none: a
// made-up count would be billed and charted as if it were real.
func openAIUsage(u *Usage) any {
	if u == nil {
		return nil
	}
	return map[string]any{"prompt_tokens": u.Input, "completion_tokens": u.Output, "total_tokens": u.Input + u.Output}
}

// afkInfo says which CLI and model answered, beside the standard fields.
func afkInfo(o Outcome) map[string]any {
	return map[string]any{"harness": o.Route.Harness, "model": o.Route.Model, "run": o.Run}
}

func (openAI) answer(w http.ResponseWriter, req *request, o Outcome, id string, now time.Time) {
	out := map[string]any{
		"id": "chatcmpl-" + id, "object": "chat.completion", "created": now.Unix(), "model": req.Model,
		"choices": []map[string]any{{
			"index": 0, "finish_reason": "stop",
			"message": map[string]any{"role": "assistant", "content": o.Text},
		}},
		"afk": afkInfo(o),
	}
	if u := openAIUsage(o.Usage); u != nil {
		out["usage"] = u
	}
	writeJSON(w, 200, out)
}

type openAIStream struct {
	s       *sse
	req     *request
	id      string
	created int64
}

func (openAI) stream(w http.ResponseWriter, req *request, id string, now time.Time) streamer {
	st := &openAIStream{s: newSSE(w), req: req, id: "chatcmpl-" + id, created: now.Unix()}
	st.chunk(map[string]any{"role": "assistant", "content": ""}, nil, nil)
	return st
}

func (st *openAIStream) chunk(delta map[string]any, finish any, extra map[string]any) {
	out := map[string]any{
		"id": st.id, "object": "chat.completion.chunk", "created": st.created, "model": st.req.Model,
		"choices": []map[string]any{{"index": 0, "delta": delta, "finish_reason": finish}},
	}
	for k, v := range extra {
		out[k] = v
	}
	st.s.event("", out)
}

func (st *openAIStream) delta(text string) { st.chunk(map[string]any{"content": text}, nil, nil) }

func (st *openAIStream) ping() { st.s.raw(": afk is working") }

func (st *openAIStream) done(o Outcome) {
	if !o.OK {
		st.s.event("", openAIError(o))
		st.s.raw("data: [DONE]")
		return
	}
	st.chunk(map[string]any{}, "stop", map[string]any{"afk": afkInfo(o)})
	if st.req.IncludeUsage {
		// The usage chunk has no choices. When the CLI reported no usage
		// it carries null, not zeros.
		st.s.event("", map[string]any{
			"id": st.id, "object": "chat.completion.chunk", "created": st.created, "model": st.req.Model,
			"choices": []any{}, "usage": openAIUsage(o.Usage),
		})
	}
	st.s.raw("data: [DONE]")
}

func newID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
