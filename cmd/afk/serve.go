package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/serve"
	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

const serveUsage = `afk serve — AFK as a model API for gateways and other clients

  afk serve [--listen host:port]
      run the API until ctrl+c. It listens on serve.listen
      (default 127.0.0.1:8484: this machine only).

  afk serve status [--json]     is it running, and where
  afk serve stop                stop the one that is running

The API speaks both common formats, so a gateway adds it like any other
provider:

  POST /v1/chat/completions     OpenAI format
  POST /v1/messages             Anthropic format
  GET  /v1/models               the model names the key can ask for

Callers sign in with an AFK key (afk keys add). A router key asks for
afk/auto or afk/<task> and AFK picks the CLI and model; a harness key
asks for <cli>/<model> on its one CLI. Each call runs that CLI headless
and returns its answer, streamed when the caller asks for a stream.

Your CLIs' own sign-ins (your subscriptions) answer calls only when
serve.plan_runs is on:  afk config set serve.plan_runs true
Off, only a gateway, a local engine or a free pool answers.

To listen beyond this machine, for a gateway running elsewhere:
  afk config set serve.listen 0.0.0.0:8484
The API is plain HTTP. Across a network you don't control, put TLS in
front of it (a reverse proxy, or a private network such as Tailscale).
`

// serveState is what a running afk serve leaves for status and stop.
type serveState struct {
	PID     int    `json:"pid"`
	Listen  string `json:"listen"`
	Started string `json:"started"`
	Version string `json:"version"`
}

func serveStatePath(paths config.Paths) string { return filepath.Join(paths.State, "serve.json") }

// readServeState is the running server's state; ok is false when none is
// running (a file left by a server that died is removed).
func readServeState(paths config.Paths) (serveState, bool) {
	var st serveState
	b, err := os.ReadFile(serveStatePath(paths))
	if err != nil || json.Unmarshal(b, &st) != nil || st.PID <= 0 {
		return serveState{}, false
	}
	if !processAlive(st.PID) {
		_ = os.Remove(serveStatePath(paths))
		return serveState{}, false
	}
	return st, true
}

func serveCmd(argv []string, stdout, stderr io.Writer) int {
	listen := ""
	asJSON := false
	var args []string
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		switch {
		case a == "-h" || a == "--help" || a == "help":
			fmt.Fprint(stdout, serveUsage)
			return 0
		case a == "--json":
			asJSON = true
		case a == "--listen" && i+1 < len(argv):
			i++
			listen = argv[i]
		case strings.HasPrefix(a, "--listen="):
			listen = strings.TrimPrefix(a, "--listen=")
		case strings.HasPrefix(a, "-"):
			fmt.Fprintf(stderr, "afk serve: unknown option %s\n", a)
			return 2
		default:
			args = append(args, a)
		}
	}
	home, _ := os.UserHomeDir()
	paths := config.PathsFor(home, os.Getenv)
	if len(args) > 0 {
		switch args[0] {
		case "status":
			st, ok := readServeState(paths)
			if asJSON {
				return printJSON(stdout, stderr, map[string]any{"schema": "afk-serve-status/1", "running": ok, "pid": st.PID, "listen": st.Listen, "started": st.Started, "version": st.Version})
			}
			if !ok {
				fmt.Fprintln(stdout, "afk serve is not running.")
				return 1
			}
			fmt.Fprintf(stdout, "afk serve is running on http://%s (pid %d, since %s).\n", st.Listen, st.PID, st.Started)
			return 0
		case "stop":
			st, ok := readServeState(paths)
			if !ok {
				fmt.Fprintln(stdout, "afk serve is not running.")
				return 0
			}
			if err := stopProcess(st.PID); err != nil {
				fmt.Fprintln(stderr, "afk serve:", err)
				return 1
			}
			for i := 0; i < 100 && processAlive(st.PID); i++ {
				time.Sleep(100 * time.Millisecond)
			}
			if processAlive(st.PID) {
				fmt.Fprintf(stderr, "afk serve: pid %d is still finishing its runs\n", st.PID)
				return 1
			}
			fmt.Fprintln(stdout, "Stopped afk serve.")
			return 0
		}
		fmt.Fprintf(stderr, "afk serve: unknown command %q\n\n%s", args[0], serveUsage)
		return 2
	}

	c := core.New()
	settings, err := c.LoadSettings("")
	if err != nil {
		fmt.Fprintln(stderr, "afk serve:", err)
		return 1
	}
	if listen == "" {
		listen = settings.ServeListen
	}
	if !config.ServeListenOK(listen) {
		fmt.Fprintf(stderr, "afk serve: %q is not an address to listen on (for example 127.0.0.1:8484)\n", listen)
		return 2
	}
	if st, ok := readServeState(paths); ok {
		fmt.Fprintf(stderr, "afk serve: already running on http://%s (pid %d); stop it with: afk serve stop\n", st.Listen, st.PID)
		return 1
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		fmt.Fprintln(stderr, "afk serve:", err)
		return 1
	}
	addr := ln.Addr().String()

	store := &apikey.Store{Path: apikey.PathFor(paths.State, os.Getenv)}
	runs := runrec.DirFor(home, os.Getenv)
	limiter := &apikey.Limiter{}
	serve.SeedLimiter(limiter, runs, time.Now())
	logLine := func(s string) {
		fmt.Fprintln(stderr, time.Now().Format("15:04:05"), s)
	}
	srv := &serve.Server{
		Keys: store, Limiter: limiter, Version: version, Log: logLine,
		Backend: &serve.CoreBackend{Core: c, RunsDir: runs},
	}
	// Runs end with the server: their context is the server's.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	hs := &http.Server{
		// A request is small and arrives at once; the answer may take as
		// long as the run does, so only reading is timed.
		Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: time.Minute, IdleTimeout: 2 * time.Minute,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}

	state := serveState{PID: os.Getpid(), Listen: addr, Started: time.Now().Format(time.RFC3339), Version: version}
	if b, err := json.Marshal(state); err == nil {
		_ = statefile.WriteFile(serveStatePath(paths), b)
	}
	defer os.Remove(serveStatePath(paths))

	for _, l := range serveBanner(addr, store, settings.ServePlanRuns) {
		fmt.Fprintln(stderr, l)
	}
	done := make(chan error, 1)
	go func() { done <- hs.Serve(ln) }()
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintln(stderr, "afk serve:", err)
			return 1
		}
		return 0
	case <-ctx.Done():
	}
	fmt.Fprintln(stderr, "afk serve: stopping")
	shut, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_ = hs.Shutdown(shut)
	return 0
}

// serveBanner is what afk serve prints when it starts.
func serveBanner(addr string, store *apikey.Store, planRuns bool) []string {
	out := []string{"afk serve · http://" + addr + "  (ctrl+c stops it)"}
	keys, err := store.List()
	active := 0
	for _, k := range keys {
		if k.Active() {
			active++
		}
	}
	switch {
	case err != nil:
		out = append(out, "  keys: "+err.Error())
	case active == 0:
		out = append(out, "  keys: none yet, so nothing can call it. Make one with: afk keys add <name>")
	default:
		out = append(out, fmt.Sprintf("  keys: %d (afk keys)", active))
	}
	if planRuns {
		out = append(out, "  your CLIs' own sign-ins: may answer calls (serve.plan_runs is on)")
	} else {
		out = append(out, "  your CLIs' own sign-ins: not used. Only a gateway, a local engine or a free pool answers.",
			"    To let your subscriptions answer: afk config set serve.plan_runs true")
	}
	if host, _, err := net.SplitHostPort(addr); err == nil {
		if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			out = append(out, "  This address is reachable from other machines, over plain HTTP. Anyone on the network path can",
				"    read the keys and prompts sent to it; use a private network or put TLS in front.")
		}
	}
	return out
}
