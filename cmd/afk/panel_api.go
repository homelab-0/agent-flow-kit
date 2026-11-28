package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/apikey"
	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/serve"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// The API tab's data and actions: what `afk keys` and `afk serve` do,
// for the panel.

func (s panelSource) apiStore() (*apikey.Store, config.Paths) {
	paths := config.PathsFor(s.c.Home, s.getenv)
	return &apikey.Store{Path: apikey.PathFor(paths.State, s.getenv)}, paths
}

func (s panelSource) now() time.Time {
	if s.c.Now != nil {
		return s.c.Now()
	}
	return time.Now()
}

// listenOpen reports whether addr is reachable from other machines.
func listenOpen(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "localhost" {
		return false
	}
	ip := net.ParseIP(host)
	return ip == nil || !ip.IsLoopback()
}

func (s panelSource) API(context.Context) (*tui.APIView, error) {
	store, paths := s.apiStore()
	st, err := s.c.LoadSettings("")
	if err != nil {
		return nil, err
	}
	keys, err := store.List()
	if err != nil {
		return nil, err
	}
	v := &tui.APIView{KeysPath: store.Path, PlanRuns: st.ServePlanRuns, PlanWarning: strings.Join(serve.PlanRunsWarning(), " ")}
	v.Server.Listen = st.ServeListen
	v.Server.Open = listenOpen(st.ServeListen)
	if run, ok := readServeState(paths); ok {
		v.Server.Running, v.Server.Addr, v.Server.PID = true, run.Listen, run.PID
		v.Server.Since, _ = time.Parse(time.RFC3339, run.Started)
		v.Server.Open = listenOpen(run.Listen)
	}
	// What each key ran in the last day, from the run records.
	now := s.now()
	runs := map[string]int{}
	last := map[string]time.Time{}
	for _, r := range runrec.Load(runrec.DirFor(s.c.Home, s.getenv), now.Add(-24*time.Hour)) {
		if r.Where != "serve" || r.Key == "" {
			continue
		}
		runs[r.Key]++
		if t, err := time.Parse(time.RFC3339, r.StartedAt); err == nil && t.After(last[r.Key]) {
			last[r.Key] = t
		}
	}
	for _, k := range keys {
		row := tui.KeyRow{Name: k.Name, Hint: k.Hint(), Kind: k.Kind, Harness: k.Harness, Models: k.Models,
			PerMinute: k.Limits.PerMinute, PerDay: k.Limits.PerDay, Concurrent: k.Limits.Concurrent,
			Dir: k.Dir, Mode: k.Mode, Revoked: !k.Active(), Created: k.Created,
			Runs: runs[k.Name], LastRun: last[k.Name], Asks: keyModelHint(k)}
		if k.Harness != "" {
			row.Display, _ = keyHarnessNames(k.Harness)
		}
		v.Keys = append(v.Keys, row)
	}
	v.Kinds = []tui.KeyKind{{ID: apikey.KindRouter, Label: "Any (AFK picks)",
		Desc: "a router key: the caller asks for afk/auto or afk/<task> and AFK picks the CLI and model"}}
	for _, h := range core.Routable {
		display, vendor := keyHarnessNames(h)
		warn := serve.HarnessKeyWarning(display, vendor, apikey.DefaultLimits(apikey.KindHarness))
		if !st.ServePlanRuns {
			warn = append(warn, "This key won't answer until your CLIs' own sign-ins are switched on for afk serve (p on this tab).")
		}
		v.Kinds = append(v.Kinds, tui.KeyKind{ID: h, Label: display + " only",
			Desc: "a harness key: the caller names the model (" + h + "/<model>) and AFK makes no routing decision", Warning: warn})
	}
	return v, nil
}

// keyUse is how a caller uses a new key.
func keyUse(k apikey.Key, paths config.Paths, listen string) []string {
	addr, running := listen, false
	if run, ok := readServeState(paths); ok {
		addr, running = run.Listen, true
	}
	out := []string{
		"Address: http://" + addr + "/v1  (OpenAI format at /v1/chat/completions, Anthropic format at /v1/messages)",
		"Model to ask for: " + keyModelHint(k),
		"Limits: " + k.Limits.String() + ". Enter on the key changes them.",
	}
	if !running {
		out = append(out, "The server is stopped. s on this tab starts it.")
	}
	return out
}

func (s panelSource) APIDo(_ context.Context, op string, args ...string) (*tui.APIResult, error) {
	store, paths := s.apiStore()
	need := func(n int) error {
		if len(args) < n {
			return fmt.Errorf("%s needs more than that", op)
		}
		return nil
	}
	listen := config.DefaultServeListen
	if st, err := s.c.LoadSettings(""); err == nil {
		listen = st.ServeListen
	}
	switch op {
	case "add":
		if err := need(2); err != nil {
			return nil, err
		}
		n := apikey.New{Name: strings.ToLower(args[0]), Kind: apikey.KindRouter}
		if args[1] != apikey.KindRouter {
			if err := checkKeyHarness(args[1]); err != nil {
				return nil, err
			}
			n.Kind, n.Harness = apikey.KindHarness, args[1]
		}
		k, token, err := store.Create(n)
		if err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: "Key " + k.Name + " made.", Name: k.Name, Secret: token, Lines: keyUse(k, paths, listen)}, nil
	case "rotate":
		if err := need(1); err != nil {
			return nil, err
		}
		k, token, err := store.Rotate(args[0])
		if err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: "Key " + k.Name + " rotated. The old secret no longer works.", Name: k.Name, Secret: token, Lines: keyUse(k, paths, listen)}, nil
	case "revoke":
		if err := need(1); err != nil {
			return nil, err
		}
		k, err := store.Revoke(args[0])
		if err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: "Revoked " + k.Name + ". It no longer works."}, nil
	case "rm":
		if err := need(1); err != nil {
			return nil, err
		}
		if err := store.Delete(args[0]); err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: "Deleted " + args[0] + "."}, nil
	case "set":
		if err := need(3); err != nil {
			return nil, err
		}
		return s.apiSet(store, args[0], args[1], strings.TrimSpace(args[2]))
	case "serve-start":
		st, err := startServe(paths)
		if err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: "afk serve is running on http://" + st.Listen + ". It keeps running after you leave AFK; s stops it. Its log is " + serveLogPath(paths) + "."}, nil
	case "serve-stop":
		msg, err := stopServe(paths)
		if err != nil {
			return nil, err
		}
		return &tui.APIResult{Text: msg}, nil
	}
	return nil, fmt.Errorf("unknown action %s", op)
}

// apiSet changes one setting of a key.
func (s panelSource) apiSet(store *apikey.Store, name, field, value string) (*tui.APIResult, error) {
	k, err := store.Get(name)
	if err != nil {
		return nil, err
	}
	none := value == "" || value == "none" || value == "off" || value == "any"
	switch field {
	case "per-minute", "per-day", "concurrent":
		n := 0
		if !none {
			if n, err = strconv.Atoi(value); err != nil || n < 0 {
				return nil, errors.New("a limit is a count, or 0 for no limit")
			}
		}
		l := k.Limits
		switch field {
		case "per-minute":
			l.PerMinute = n
		case "per-day":
			l.PerDay = n
		default:
			l.Concurrent = n
		}
		if k, err = store.SetLimits(name, l); err != nil {
			return nil, err
		}
	case "models":
		var models []string
		if !none {
			for _, m := range strings.Split(value, ",") {
				if m = strings.TrimSpace(m); m != "" {
					models = append(models, m)
				}
			}
		}
		if k, err = store.SetModels(name, models); err != nil {
			return nil, err
		}
	case "dir":
		dir, mode := "", ""
		if !none {
			if dir, err = keyDir(value); err != nil {
				return nil, err
			}
			mode = k.Mode
		}
		if k, err = store.SetRun(name, dir, mode); err != nil {
			return nil, err
		}
	case "mode":
		if k, err = store.SetRun(name, k.Dir, value); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("a key has no %s", field)
	}
	does := "its calls can only answer"
	if k.Dir != "" {
		does = "its calls are " + k.RunMode() + " in " + k.Dir
	}
	return &tui.APIResult{Text: k.Name + " saved: " + k.Limits.String() + " · " + does + ". A running server uses it from the next call."}, nil
}

func serveLogPath(paths config.Paths) string { return filepath.Join(paths.State, "serve.log") }

// serveExe is the afk that a background server runs (tests replace it).
var serveExe = os.Executable

// startServe runs afk serve in the background, detached from this
// terminal, and waits until it is listening.
func startServe(paths config.Paths, args ...string) (serveState, error) {
	if st, ok := readServeState(paths); ok {
		return st, fmt.Errorf("already running on http://%s (pid %d)", st.Listen, st.PID)
	}
	exe, err := serveExe()
	if err != nil {
		return serveState{}, err
	}
	if err := os.MkdirAll(paths.State, 0o700); err != nil {
		return serveState{}, err
	}
	logPath := serveLogPath(paths)
	logf, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return serveState{}, err
	}
	defer logf.Close()
	cmd := exec.Command(exe, append([]string{"serve"}, args...)...)
	cmd.Stdout, cmd.Stderr = logf, logf
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home // not the project this AFK was opened in
	}
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return serveState{}, err
	}
	exited := make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	why := func() error {
		b, _ := os.ReadFile(logPath)
		lines := strings.Split(strings.TrimSpace(string(b)), "\n")
		if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
			return errors.New(strings.TrimPrefix(last, "afk serve: "))
		}
		return errors.New("afk serve stopped as soon as it started; see " + logPath)
	}
	for i := 0; i < 100; i++ {
		select {
		case <-exited:
			return serveState{}, why()
		case <-time.After(50 * time.Millisecond):
		}
		if st, ok := readServeState(paths); ok && st.PID == cmd.Process.Pid {
			return st, nil
		}
	}
	return serveState{}, errors.New("afk serve did not start listening within 5 seconds; see " + logPath)
}

// stopServe stops the running server and says what happened.
func stopServe(paths config.Paths) (string, error) {
	st, ok := readServeState(paths)
	if !ok {
		return "afk serve is not running.", nil
	}
	if err := stopProcess(st.PID); err != nil {
		return "", err
	}
	for i := 0; i < 100 && processAlive(st.PID); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	if processAlive(st.PID) {
		return "", fmt.Errorf("pid %d is still finishing its runs", st.PID)
	}
	return "Stopped afk serve.", nil
}
