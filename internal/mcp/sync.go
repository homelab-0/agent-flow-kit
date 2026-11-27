package mcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// Schema is the version of the state file.
const Schema = "afk-mcp-state/1"

// Target is one CLI's MCP config file.
type Target struct {
	Harness string `json:"harness"`
	File    string `json:"file"`
	Format  string `json:"format"`
}

// Env is where things are.
type Env struct {
	Config   string            // mcp.toml
	Gateways map[string]string // gateway id → its MCP endpoint, from config.toml
	State    string            // ~/.config/afk/state/mcp.json
	Now      func() time.Time
}

func (e Env) now() time.Time {
	if e.Now == nil {
		return time.Now()
	}
	return e.Now()
}

// Cell is one server in one CLI.
type Cell string

const (
	Synced      Cell = "synced"      // the CLI has AFK's entry
	Pending     Cell = "pending"     // a sync will add, update or adopt it
	Drifted     Cell = "drifted"     // edited in the CLI since AFK wrote it
	Off         Cell = "off"         // not given to this CLI
	Conflict    Cell = "conflict"    // the CLI has its own entry of that name
	Removing    Cell = "removing"    // a sync will remove AFK's entry (turned off)
	Orphan      Cell = "orphan"      // AFK's entry for a server no longer listed
	Unmanaged   Cell = "unmanaged"   // nothing here, and nothing to do
	Unsupported Cell = "unsupported" // this CLI can't take the server as set up
	Broken      Cell = "error"       // the CLI's file can't be read
)

type state struct {
	Schema  string              `json:"schema"`
	Managed map[string]managed  `json:"managed"` // by "harness/server"
	Off     map[string][]string `json:"off"`     // per server, CLIs turned off here
	Tested  map[string]Tested   `json:"tested"`  // last test per server
}

type managed struct {
	Hash     string `json:"hash"`
	SyncedAt string `json:"synced_at"`
}

// Tested is a server's last tools/list check.
type Tested struct {
	OK    bool      `json:"ok"`
	Tools int       `json:"tools"`
	Error string    `json:"error,omitempty"`
	At    time.Time `json:"at"`
}

func key(h, n string) string { return h + "/" + n }

func (e Env) backupDir() string { return filepath.Join(filepath.Dir(e.State), "backups", "mcp") }

func (e Env) load() (state, error) {
	st := state{Schema: Schema, Managed: map[string]managed{}, Off: map[string][]string{}, Tested: map[string]Tested{}}
	b, err := os.ReadFile(e.State)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(b, &st); err != nil {
		return st, fmt.Errorf("%s: %w", e.State, err)
	}
	if st.Managed == nil {
		st.Managed = map[string]managed{}
	}
	if st.Off == nil {
		st.Off = map[string][]string{}
	}
	if st.Tested == nil {
		st.Tested = map[string]Tested{}
	}
	return st, nil
}

func (e Env) save(st state) error {
	st.Schema = Schema
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return statefile.WriteJSON(e.State, append(b, '\n'))
}

func (e Env) lock() (*statefile.Lock, error) {
	if err := os.MkdirAll(filepath.Dir(e.State), 0o700); err != nil {
		return nil, err
	}
	return statefile.Acquire(e.State+".lock", 10*time.Second, 5*time.Minute)
}

// Status is every server in every CLI.
type Status struct {
	Config   string            `json:"config"`
	Servers  []Server          `json:"servers"`
	Targets  []Target          `json:"targets"`
	Rows     []Row             `json:"rows"`
	Problems []string          `json:"problems,omitempty"`
	Actions  []Action          `json:"actions"`
	Drift    []DriftInfo       `json:"drift,omitempty"`
	Tested   map[string]Tested `json:"tested,omitempty"`
	plan     map[string]*action
}

// Row is one server across the CLIs.
type Row struct {
	Name   string            `json:"name"`
	Listed bool              `json:"listed"` // false: only AFK's old entries are left
	Cells  map[string]Cell   `json:"cells"`
	Notes  map[string]string `json:"notes,omitempty"` // why a cell is unsupported or broken
}

// DriftInfo is an entry edited in a CLI.
type DriftInfo struct {
	Server  string `json:"server"`
	Harness string `json:"harness"`
	File    string `json:"file"`
}

// Action is one change a sync makes.
type Action struct {
	Kind    string `json:"kind"` // add, update, adopt, remove
	Server  string `json:"server"`
	Harness string `json:"harness"`
	File    string `json:"file"`
}

type action struct {
	Action
	entry map[string]any // nil for remove
}

// fileState is one CLI file as read.
type fileState struct {
	raw     []byte
	exists  bool
	entries map[string]any
	managed map[string]bool // nil: every entry could be AFK's
	err     error
}

func readTarget(t Target) fileState {
	f, ok := formatFor(t.Format)
	if !ok {
		return fileState{err: fmt.Errorf("unknown format %q", t.Format)}
	}
	b, err := os.ReadFile(t.File)
	if errors.Is(err, fs.ErrNotExist) {
		return fileState{entries: map[string]any{}}
	}
	if err != nil {
		return fileState{err: err}
	}
	ent, man, err := f.read(b)
	if err != nil {
		return fileState{err: fmt.Errorf("%s: %w", t.File, err)}
	}
	return fileState{raw: b, exists: true, entries: ent, managed: man}
}

// Scan works out each server's state in each CLI and the sync plan. It
// changes nothing.
func (e Env) Scan(targets []Target) (*Status, error) {
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	return e.scan(st, targets)
}

func (e Env) scan(st state, targets []Target) (*Status, error) {
	servers, err := Load(e.Config, e.Gateways)
	if err != nil {
		return nil, err
	}
	s := &Status{Config: e.Config, Servers: servers, Targets: targets, Rows: []Row{}, Actions: []Action{},
		Tested: st.Tested, plan: map[string]*action{}}
	if s.Servers == nil {
		s.Servers = []Server{}
	}
	byName := map[string]Server{}
	all := map[string]bool{}
	for _, sv := range servers {
		byName[sv.Name] = sv
		all[sv.Name] = true
	}
	for k := range st.Managed {
		_, n, _ := strings.Cut(k, "/")
		all[n] = true
	}
	var order []string
	for n := range all {
		order = append(order, n)
	}
	sort.Strings(order)
	files := map[string]fileState{}
	for _, t := range targets {
		fs := readTarget(t)
		files[t.Harness] = fs
		if fs.err != nil {
			s.Problems = append(s.Problems, t.Harness+": "+fs.err.Error())
		}
	}
	for _, n := range order {
		sv, listed := byName[n]
		row := Row{Name: n, Listed: listed, Cells: map[string]Cell{}, Notes: map[string]string{}}
		for _, t := range targets {
			c, note := e.cell(st, s, t, files[t.Harness], sv, listed, n)
			row.Cells[t.Harness] = c
			if note != "" {
				row.Notes[t.Harness] = note
			}
		}
		if !listed {
			keep := false
			for _, c := range row.Cells {
				keep = keep || (c != Unmanaged && c != Broken)
			}
			if !keep {
				continue
			}
		}
		if len(row.Notes) == 0 {
			row.Notes = nil
		}
		s.Rows = append(s.Rows, row)
	}
	for _, t := range targets {
		for _, n := range order {
			if a := s.plan[key(t.Harness, n)]; a != nil {
				s.Actions = append(s.Actions, a.Action)
			}
		}
	}
	return s, nil
}

func (e Env) cell(st state, s *Status, t Target, f fileState, sv Server, listed bool, n string) (Cell, string) {
	if f.err != nil {
		return Broken, f.err.Error()
	}
	fm, _ := formatFor(t.Format)
	wanted := listed && sv.For(t.Harness) && !contains(st.Off[n], t.Harness)
	var desired map[string]any
	var why string
	if wanted {
		d, err := fm.entry(sv)
		if err != nil {
			wanted, why = false, err.Error()
		}
		desired = d
	}
	plan := func(kind string) {
		s.plan[key(t.Harness, n)] = &action{Action: Action{Kind: kind, Server: n, Harness: t.Harness, File: t.File}, entry: desired}
	}
	cur, has := f.entries[n]
	m, isManaged := st.Managed[key(t.Harness, n)]
	if f.managed != nil && !f.managed[n] {
		isManaged = false // outside AFK's section it's yours
	}
	if !has {
		switch {
		case why != "":
			return Unsupported, why
		case !listed:
			return Unmanaged, ""
		case !wanted:
			return Off, ""
		}
		plan("add")
		return Pending, ""
	}
	if !isManaged {
		if wanted && f.managed == nil && canon(cur) == canon(desired) {
			plan("adopt") // the same entry, added by hand: AFK takes it on
			return Pending, ""
		}
		if !listed {
			return Unmanaged, ""
		}
		return Conflict, "your own entry named " + n + "; AFK leaves it alone"
	}
	if canon(cur) != m.Hash {
		s.Drift = append(s.Drift, DriftInfo{Server: n, Harness: t.Harness, File: t.File})
		return Drifted, ""
	}
	switch {
	case !listed:
		plan("remove")
		return Orphan, ""
	case why != "":
		plan("remove")
		return Removing, why
	case !wanted:
		plan("remove")
		return Removing, ""
	case canon(cur) != canon(desired):
		plan("update")
		return Pending, ""
	}
	return Synced, ""
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// Result is what a change did.
type Result struct {
	Done   []Action `json:"done"`
	Backup string   `json:"backup,omitempty"`
}

// Sync makes the plan Scan shows, under the lock. Each CLI's file is
// written once; if any write fails, every file already written is put
// back.
func (e Env) Sync(targets []Target) (*Result, error) {
	l, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	s, err := e.scan(st, targets)
	if err != nil {
		return nil, err
	}
	var acts []*action
	for _, a := range s.Actions {
		acts = append(acts, s.plan[key(a.Harness, a.Server)])
	}
	return e.apply(st, targets, acts)
}

func (e Env) newBackup() string {
	stamp := e.now().UTC().Format("20060102T150405Z")
	p := filepath.Join(e.backupDir(), stamp)
	for i := 2; exists(p); i++ {
		p = filepath.Join(e.backupDir(), fmt.Sprintf("%s-%d", stamp, i))
	}
	return p
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// realPath follows a symlinked config file (dotfiles), so the link stays.
func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func (e Env) apply(st state, targets []Target, acts []*action) (*Result, error) {
	res := &Result{Done: []Action{}}
	if len(acts) == 0 {
		return res, nil
	}
	backup := e.newBackup()
	type written struct {
		path    string
		before  []byte
		existed bool
	}
	var done []written
	rollback := func(cause error) (*Result, error) {
		for i := len(done) - 1; i >= 0; i-- {
			w := done[i]
			var err error
			if w.existed {
				err = statefile.WriteFile(w.path, w.before)
			} else {
				err = os.Remove(w.path)
			}
			if err != nil {
				cause = fmt.Errorf("%w; putting %s back also failed: %v (the backup is in %s)", cause, w.path, err, backup)
			}
		}
		return nil, cause
	}
	for _, t := range targets {
		var mine []*action
		for _, a := range acts {
			if a.Harness == t.Harness {
				mine = append(mine, a)
			}
		}
		if len(mine) == 0 {
			continue
		}
		f := readTarget(t)
		if f.err != nil {
			return rollback(f.err)
		}
		fm, _ := formatFor(t.Format)
		set := map[string]map[string]any{}
		var del []string
		for _, a := range mine {
			if a.Kind == "remove" {
				del = append(del, a.Server)
			} else if a.Kind != "adopt" {
				set[a.Server] = a.entry
			}
		}
		path := realPath(t.File)
		if len(set) > 0 || len(del) > 0 {
			out, err := fm.write(f.raw, set, del)
			if err != nil {
				return rollback(fmt.Errorf("%s: %w", t.File, err))
			}
			if f.exists {
				bp := filepath.Join(backup, t.Harness, filepath.Base(path))
				if err := os.MkdirAll(filepath.Dir(bp), 0o700); err != nil {
					return rollback(err)
				}
				if err := os.WriteFile(bp, f.raw, 0o600); err != nil {
					return rollback(err)
				}
				res.Backup = backup
			}
			if err := statefile.WriteFile(path, out); err != nil {
				return rollback(fmt.Errorf("%s: %w", t.File, err))
			}
			done = append(done, written{path, f.raw, f.exists})
		}
		// Check what the CLI will now read.
		after := readTarget(t)
		if after.err != nil {
			return rollback(after.err)
		}
		for _, a := range mine {
			got, has := after.entries[a.Server]
			switch {
			case a.Kind == "remove" && has:
				return rollback(fmt.Errorf("%s: %s is still there after the write", t.File, a.Server))
			case a.Kind != "remove" && (!has || canon(got) != canon(a.entry)):
				return rollback(fmt.Errorf("%s: %s didn't read back as written", t.File, a.Server))
			}
		}
	}
	now := e.now().UTC().Format(time.RFC3339)
	for _, a := range acts {
		if a.Kind == "remove" {
			delete(st.Managed, key(a.Harness, a.Server))
		} else {
			st.Managed[key(a.Harness, a.Server)] = managed{Hash: canon(a.entry), SyncedAt: now}
		}
		res.Done = append(res.Done, a.Action)
	}
	if err := e.save(st); err != nil {
		return rollback(err)
	}
	e.pruneBackups(20)
	return res, nil
}

func (e Env) pruneBackups(n int) {
	ents, err := os.ReadDir(e.backupDir())
	if err != nil || len(ents) <= n {
		return
	}
	var names []string
	for _, d := range ents {
		if d.IsDir() {
			names = append(names, d.Name())
		}
	}
	sort.Strings(names)
	for _, old := range names[:max(0, len(names)-n)] {
		_ = os.RemoveAll(filepath.Join(e.backupDir(), old))
	}
}

func find(targets []Target, h string) (Target, bool) {
	for _, t := range targets {
		if t.Harness == h {
			return t, true
		}
	}
	return Target{}, false
}

// Keep accepts a CLI's edited entry as its own: AFK stops managing it
// (it then shows as your own entry, and is never touched).
func (e Env) Keep(targets []Target, server, h string) (*Result, error) {
	t, ok := find(targets, h)
	if !ok {
		return nil, fmt.Errorf("%s has no MCP config AFK manages", h)
	}
	l, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	if _, ok := st.Managed[key(h, server)]; !ok {
		return nil, fmt.Errorf("%s in %s isn't an entry AFK wrote", server, h)
	}
	delete(st.Managed, key(h, server))
	if !contains(st.Off[server], h) {
		st.Off[server] = append(st.Off[server], h)
		sort.Strings(st.Off[server])
	}
	if err := e.save(st); err != nil {
		return nil, err
	}
	return &Result{Done: []Action{{Kind: "keep", Server: server, Harness: h, File: t.File}}}, nil
}

// Restore writes AFK's entry back over a CLI's edited one (the file is
// backed up first).
func (e Env) Restore(targets []Target, server, h string) (*Result, error) {
	t, ok := find(targets, h)
	if !ok {
		return nil, fmt.Errorf("%s has no MCP config AFK manages", h)
	}
	l, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	if _, ok := st.Managed[key(h, server)]; !ok {
		return nil, fmt.Errorf("%s in %s isn't an entry AFK wrote, so AFK won't replace it", server, h)
	}
	servers, err := Load(e.Config, e.Gateways)
	if err != nil {
		return nil, err
	}
	for _, sv := range servers {
		if sv.Name != server {
			continue
		}
		fm, _ := formatFor(t.Format)
		ent, err := fm.entry(sv)
		if err != nil {
			return nil, err
		}
		return e.apply(st, []Target{t}, []*action{{Action: Action{Kind: "update", Server: server, Harness: h, File: t.File}, entry: ent}})
	}
	// No longer listed: restoring means taking AFK's entry out.
	return e.apply(st, []Target{t}, []*action{{Action: Action{Kind: "remove", Server: server, Harness: h, File: t.File}}})
}

// SetEnabled turns a server on or off for one CLI here (on top of
// mcp.toml's harnesses list). The next sync applies it.
func (e Env) SetEnabled(server, h string, on bool) error {
	if !ValidName(server) {
		return fmt.Errorf("%q is not a server name", server)
	}
	l, err := e.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return err
	}
	var off []string
	for _, x := range st.Off[server] {
		if x != h {
			off = append(off, x)
		}
	}
	if !on {
		off = append(off, h)
		sort.Strings(off)
	}
	if len(off) == 0 {
		delete(st.Off, server)
	} else {
		st.Off[server] = off
	}
	return e.save(st)
}

// Record saves a server's test result.
func (e Env) Record(server string, t Tested) error {
	l, err := e.lock()
	if err != nil {
		return err
	}
	defer l.Release()
	st, err := e.load()
	if err != nil {
		return err
	}
	st.Tested[server] = t
	return e.save(st)
}
