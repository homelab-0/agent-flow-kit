// Package serve is afk serve: AFK's own model API. A gateway (LiteLLM,
// OpenRouter-style proxies, any OpenAI- or Anthropic-compatible client)
// calls it with an AFK key, and AFK answers by running an agent CLI
// headless.
//
// The package has three parts. translate.go turns a chat request into the
// one prompt a CLI takes. backend.go runs it: routed for a router key,
// on one named CLI and model for a harness key. openai.go and
// anthropic.go write the answer back in the caller's own API, whole or
// streamed.
package serve

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
)

// The most a request may carry. A prompt goes to the CLI as one command
// argument, and Linux allows 128 KiB for one.
const (
	MaxBody   = 8 << 20
	MaxPrompt = 120 << 10
)

// Server is the HTTP API.
type Server struct {
	Keys    *apikey.Store
	Limiter *apikey.Limiter
	Backend Backend
	Version string
	// Log gets one line per call: the key's name, the model asked for,
	// the route that answered and the status. Never a prompt or an
	// answer.
	Log func(string)
	// Now is the clock (tests).
	Now func() time.Time
	// Ping is how often a waiting stream is kept alive (0: 15 seconds).
	Ping time.Duration
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Handler is the API's routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "service": "afk", "version": s.Version})
	})
	mux.HandleFunc("GET /v1/models", s.models)
	mux.HandleFunc("GET /v1/models/{id...}", s.model)
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) { s.call(w, r, openAI{}) })
	mux.HandleFunc("POST /v1/messages", func(w http.ResponseWriter, r *http.Request) { s.call(w, r, anthropic{}) })
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		apiFor(r).fail(w, Outcome{Status: 404, Kind: KindNotFound, Error: "AFK serves /v1/chat/completions, /v1/messages and /v1/models"})
	})
	return mux
}

// api is one of the two wire formats.
type api interface {
	parse(body []byte) (*request, error)
	// fail writes a failure as this API's error document.
	fail(w http.ResponseWriter, o Outcome)
	// answer writes a whole answer.
	answer(w http.ResponseWriter, req *request, o Outcome, id string, now time.Time)
	// stream starts a streamed answer.
	stream(w http.ResponseWriter, req *request, id string, now time.Time) streamer
}

// streamer writes a streamed answer. Its methods are called from one
// goroutine at a time.
type streamer interface {
	delta(text string)
	ping()
	// done ends the stream: with the outcome's usage after an answer,
	// with an error event after a failure.
	done(o Outcome)
}

// apiFor picks the error format for a path that names no API: Anthropic
// clients send anthropic-version.
func apiFor(r *http.Request) api {
	if r.Header.Get("anthropic-version") != "" || strings.HasPrefix(r.URL.Path, "/v1/messages") {
		return anthropic{}
	}
	return openAI{}
}

// auth finds the key a request carries: Authorization: Bearer (OpenAI
// clients) or x-api-key (Anthropic clients).
func (s *Server) auth(r *http.Request) (apikey.Key, *Outcome) {
	token := r.Header.Get("x-api-key")
	if h := r.Header.Get("Authorization"); h != "" {
		if t, ok := strings.CutPrefix(h, "Bearer "); ok {
			token = strings.TrimSpace(t)
		}
	}
	if token == "" {
		o := failure(401, KindAuth, "no API key: send an AFK key as Authorization: Bearer <key> or x-api-key")
		return apikey.Key{}, &o
	}
	k, ok := s.Keys.Verify(token)
	if !ok {
		o := failure(401, KindAuth, "that is not a working AFK key (revoked, rotated or mistyped)")
		return apikey.Key{}, &o
	}
	return k, nil
}

func (s *Server) models(w http.ResponseWriter, r *http.Request) {
	a := apiFor(r)
	k, deny := s.auth(r)
	if deny != nil {
		a.fail(w, *deny)
		return
	}
	list, err := s.Backend.Models(r.Context(), k)
	if err != nil {
		a.fail(w, failure(500, KindUpstream, "%v", err))
		return
	}
	created := k.Created.Unix()
	if _, ok := a.(anthropic); ok {
		data := []map[string]any{}
		for _, m := range list {
			data = append(data, map[string]any{"type": "model", "id": m.ID, "display_name": m.ID, "created_at": k.Created.UTC().Format(time.RFC3339)})
		}
		out := map[string]any{"data": data, "has_more": false, "first_id": nil, "last_id": nil}
		if len(list) > 0 {
			out["first_id"], out["last_id"] = list[0].ID, list[len(list)-1].ID
		}
		writeJSON(w, 200, out)
		return
	}
	data := []map[string]any{}
	for _, m := range list {
		data = append(data, map[string]any{"id": m.ID, "object": "model", "created": created, "owned_by": m.Owner})
	}
	writeJSON(w, 200, map[string]any{"object": "list", "data": data})
}

func (s *Server) model(w http.ResponseWriter, r *http.Request) {
	a := apiFor(r)
	k, deny := s.auth(r)
	if deny != nil {
		a.fail(w, *deny)
		return
	}
	list, err := s.Backend.Models(r.Context(), k)
	if err != nil {
		a.fail(w, failure(500, KindUpstream, "%v", err))
		return
	}
	id := r.PathValue("id")
	for _, m := range list {
		if m.ID == id {
			if _, ok := a.(anthropic); ok {
				writeJSON(w, 200, map[string]any{"type": "model", "id": m.ID, "display_name": m.ID, "created_at": k.Created.UTC().Format(time.RFC3339)})
				return
			}
			writeJSON(w, 200, map[string]any{"id": m.ID, "object": "model", "created": k.Created.Unix(), "owned_by": m.Owner})
			return
		}
	}
	a.fail(w, failure(404, KindNotFound, "this key has no model %q", id))
}

// call answers one chat request.
func (s *Server) call(w http.ResponseWriter, r *http.Request, a api) {
	started := s.now()
	k, deny := s.auth(r)
	if deny != nil {
		a.fail(w, *deny)
		s.log("-", "-", *deny, started)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBody))
	if err != nil {
		var big *http.MaxBytesError
		o := failure(400, KindInvalid, "the request body could not be read")
		if errors.As(err, &big) {
			o = failure(413, KindTooLarge, "the request is larger than %d MiB", MaxBody>>20)
		}
		a.fail(w, o)
		s.log(k.Name, "-", o, started)
		return
	}
	req, err := a.parse(body)
	var text string
	if err == nil {
		text, err = prompt(req.Turns)
	}
	if err != nil {
		o := failure(400, KindInvalid, "%s", err.Error())
		a.fail(w, o)
		s.log(k.Name, "-", o, started)
		return
	}
	if len(text) > MaxPrompt {
		o := failure(413, KindTooLarge, "the conversation is %d KiB as a prompt; AFK passes at most %d KiB to a CLI. Send fewer or shorter messages", len(text)>>10, MaxPrompt>>10)
		a.fail(w, o)
		s.log(k.Name, req.Model, o, started)
		return
	}
	release, denied := s.Limiter.Acquire(k)
	if denied != nil {
		o := Outcome{Status: 429, Kind: KindRateLimit, RetryAfter: denied.RetryAfter,
			Error: denied.Error() + ". The limit is set on the key in AFK and can be raised or turned off there"}
		a.fail(w, o)
		s.log(k.Name, req.Model, o, started)
		return
	}
	defer release()
	if len(req.Ignored) > 0 {
		w.Header().Set("X-AFK-Ignored", strings.Join(req.Ignored, ", "))
	}
	id := newID()
	c := Call{Key: k, Model: req.Model, Effort: req.Effort, Prompt: text}
	if !req.Stream {
		o := s.Backend.Run(r.Context(), c)
		if !o.OK {
			a.fail(w, o)
		} else {
			routeHeaders(w, o)
			a.answer(w, req, o, id, started)
		}
		s.log(k.Name, req.Model, o, started)
		return
	}

	// A streamed answer: the run goes on in the background, and this
	// goroutine alone writes to the caller: text as it comes, and a ping
	// while there is none, so a gateway doesn't take a long silence for a
	// dead connection.
	//
	// The stream opens with the first text or the first ping, not before.
	// A call that fails before either (the model isn't the key's, the
	// plan is out of quota) is then still answered with its own HTTP
	// status, which is what a gateway needs to move on to its next
	// provider.
	var st streamer
	open := func() {
		if st == nil {
			st = a.stream(w, req, id, started)
		}
	}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	deltas := make(chan string, 64)
	result := make(chan Outcome, 1)
	c.Delta = func(t string) {
		select {
		case deltas <- t:
		case <-ctx.Done():
		}
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		result <- s.Backend.Run(ctx, c)
	}()
	every := s.Ping
	if every <= 0 {
		every = 15 * time.Second
	}
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		select {
		case t := <-deltas:
			open()
			st.delta(t)
		case <-tick.C:
			open()
			st.ping()
		case o := <-result:
			wg.Wait()
			// Whatever text was still on its way comes first.
			for more := true; more; {
				select {
				case t := <-deltas:
					open()
					st.delta(t)
				default:
					more = false
				}
			}
			if st == nil && !o.OK {
				a.fail(w, o)
				s.log(k.Name, req.Model, o, started)
				return
			}
			open()
			if o.OK && !o.Streamed && o.Text != "" {
				st.delta(o.Text)
			}
			st.done(o)
			s.log(k.Name, req.Model, o, started)
			return
		case <-r.Context().Done():
			// The caller hung up: the run is stopped with it.
			cancel()
			o := <-result
			wg.Wait()
			if o.OK || o.Status == 0 {
				o = Outcome{Status: 499, Kind: KindUpstream, Error: "the caller went away", Route: o.Route, Run: o.Run}
			}
			s.log(k.Name, req.Model, o, started)
			return
		}
	}
}

func routeHeaders(w http.ResponseWriter, o Outcome) {
	if o.Route.Harness != "" {
		w.Header().Set("X-AFK-Route", o.Route.Harness+"/"+o.Route.Model)
	}
	if o.Run != "" {
		w.Header().Set("X-AFK-Run", o.Run)
	}
}

func (s *Server) log(key, model string, o Outcome, started time.Time) {
	if s.Log == nil {
		return
	}
	status := o.Status
	if o.OK {
		status = 200
	}
	route := "-"
	if o.Route.Harness != "" {
		route = o.Route.Harness + "/" + o.Route.Model
	}
	if model == "" {
		model = "-"
	}
	line := fmt.Sprintf("key=%s model=%s route=%s status=%d time=%s", key, clean(model), clean(route), status, s.now().Sub(started).Round(100*time.Millisecond))
	if o.Run != "" {
		line += " run=" + o.Run
	}
	if !o.OK && o.Kind != "" {
		line += " error=" + o.Kind
	}
	s.Log(line)
}

// clean keeps a caller's text from breaking a log line.
func clean(s string) string {
	if len(s) > 80 {
		s = s[:80]
	}
	return strings.Map(func(r rune) rune {
		if r <= 0x20 || r == 0x7f || r == '=' {
			return '_'
		}
		return r
	}, s)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"error":"encoding"}`, 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(append(b, '\n'))
}

func retryAfter(w http.ResponseWriter, o Outcome) {
	if o.RetryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(o.RetryAfter.Seconds()))))
	}
}

// sse writes server-sent events.
type sse struct {
	w  http.ResponseWriter
	rc *http.ResponseController
}

func newSSE(w http.ResponseWriter) *sse {
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	s := &sse{w: w, rc: http.NewResponseController(w)}
	_ = s.rc.Flush()
	return s
}

// event writes one event; name "" leaves the event line out.
func (s *sse) event(name string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	if name != "" {
		_, _ = io.WriteString(s.w, "event: "+name+"\n")
	}
	_, _ = s.w.Write(append(append([]byte("data: "), b...), '\n', '\n'))
	_ = s.rc.Flush()
}

func (s *sse) raw(line string) {
	_, _ = io.WriteString(s.w, line+"\n\n")
	_ = s.rc.Flush()
}
