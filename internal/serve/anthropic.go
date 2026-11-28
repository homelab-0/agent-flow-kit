package serve

import (
	"net/http"
	"time"
)

// anthropic is the Messages API.
type anthropic struct{}

func (anthropic) parse(body []byte) (*request, error) { return parseAnthropic(body) }

var anthropicTypes = map[string]string{
	KindInvalid: "invalid_request_error", KindNotFound: "not_found_error", KindTooLarge: "request_too_large",
	KindAuth: "authentication_error", KindPermission: "permission_error", KindRateLimit: "rate_limit_error",
	KindOverloaded: "overloaded_error", KindUpstream: "api_error",
}

func anthropicError(o Outcome) map[string]any {
	return map[string]any{"type": "error", "error": map[string]any{"type": anthropicTypes[o.Kind], "message": o.Error}}
}

func (anthropic) fail(w http.ResponseWriter, o Outcome) {
	retryAfter(w, o)
	writeJSON(w, o.Status, anthropicError(o))
}

// anthropicUsage is the usage object. The Messages API requires both
// counts, so a run whose CLI reported none carries zeros, and the
// X-AFK-Usage header (or the afk field of a stream's last event) says
// they are not a measurement.
func anthropicUsage(u *Usage) map[string]any {
	if u == nil {
		return map[string]any{"input_tokens": 0, "output_tokens": 0}
	}
	return map[string]any{"input_tokens": u.Input, "output_tokens": u.Output}
}

func usageKnown(u *Usage) string {
	if u == nil {
		return "not-reported"
	}
	return "reported"
}

func (anthropic) answer(w http.ResponseWriter, req *request, o Outcome, id string, _ time.Time) {
	w.Header().Set("X-AFK-Usage", usageKnown(o.Usage))
	info := afkInfo(o)
	info["usage"] = usageKnown(o.Usage)
	writeJSON(w, 200, map[string]any{
		"id": "msg_" + id, "type": "message", "role": "assistant", "model": req.Model,
		"content":     []map[string]any{{"type": "text", "text": o.Text}},
		"stop_reason": "end_turn", "stop_sequence": nil,
		"usage": anthropicUsage(o.Usage),
		"afk":   info,
	})
}

type anthropicStream struct {
	s *sse
}

func (anthropic) stream(w http.ResponseWriter, req *request, id string, _ time.Time) streamer {
	st := &anthropicStream{s: newSSE(w)}
	st.s.event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
		"id": "msg_" + id, "type": "message", "role": "assistant", "model": req.Model, "content": []any{},
		"stop_reason": nil, "stop_sequence": nil, "usage": anthropicUsage(nil),
	}})
	st.s.event("content_block_start", map[string]any{"type": "content_block_start", "index": 0,
		"content_block": map[string]any{"type": "text", "text": ""}})
	return st
}

func (st *anthropicStream) delta(text string) {
	st.s.event("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0,
		"delta": map[string]any{"type": "text_delta", "text": text}})
}

func (st *anthropicStream) ping() { st.s.event("ping", map[string]any{"type": "ping"}) }

func (st *anthropicStream) done(o Outcome) {
	if !o.OK {
		st.s.event("error", anthropicError(o))
		return
	}
	info := afkInfo(o)
	info["usage"] = usageKnown(o.Usage)
	st.s.event("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
	st.s.event("message_delta", map[string]any{"type": "message_delta",
		"delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil},
		"usage": anthropicUsage(o.Usage), "afk": info})
	st.s.event("message_stop", map[string]any{"type": "message_stop"})
}
