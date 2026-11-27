// Package skills keeps one copy of every skill (~/.config/afk/skills) and
// syncs it into each agent CLI's own skills directory.
//
// Every write into a CLI's directory is planned first, made under a lock,
// backed up, put in place with a rename, verified, and rolled back if any
// step fails. AFK only ever changes a skill it put there itself: a skill
// you wrote in a CLI's directory is never touched, and a synced skill you
// edited there is left alone until you say which copy wins.
package skills

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// Schema is the version of the state file.
const Schema = "afk-skills-state/1"

// maxSkillBytes bounds one skill's files: a skill is instructions and a
// few scripts, not a dataset.
const maxSkillBytes = 20 << 20

// Target is one CLI's skills directory.
type Target struct {
	Harness string `json:"harness"`
	Dir     string `json:"dir"`
}

// Env is where things are.
type Env struct {
	// Central is the one copy of every skill (~/.config/afk/skills).
	Central string
	// State is the state file (~/.config/afk/state/skills.json); its
	// directory also holds the lock and the backups.
	State string
	Now   func() time.Time
	// Ask is set for a project's .agents/skills: each skill waits for a
	// choice (SetScope) before AFK copies it anywhere. "project" copies
	// it into the CLIs' project folders; "global" leaves that to the
	// central skills it was copied into.
	Ask bool
}

// Scopes a project skill can be given.
const (
	ScopeProject = "project"
	ScopeGlobal  = "global"
)

func (e Env) now() time.Time {
	if e.Now == nil {
		return time.Now()
	}
	return e.Now()
}

// Cell is one skill in one CLI.
type Cell string

const (
	Synced    Cell = "synced"    // the CLI has the central copy
	Pending   Cell = "pending"   // a sync will add or update it
	Drifted   Cell = "drifted"   // edited in the CLI since AFK synced it
	Off       Cell = "off"       // turned off for this CLI
	Conflict  Cell = "conflict"  // the CLI has its own skill of that name
	Removing  Cell = "removing"  // a sync will remove AFK's copy (turned off)
	Orphan    Cell = "orphan"    // AFK's copy of a skill no longer central
	Unmanaged Cell = "unmanaged" // nothing here, and nothing to do
	Ask       Cell = "ask"       // a project skill waiting for its scope
	Global    Cell = "global"    // a project skill installed for every project
)

// state is the state file.
type state struct {
	Schema string `json:"schema"`
	// Managed are the copies AFK put in place, by "harness/skill", with
	// the hash they had then.
	Managed map[string]managed `json:"managed"`
	// Off lists, per skill, the CLIs it is turned off for.
	Off map[string][]string `json:"off"`
	// Scope is each project skill's scope (Env.Ask only).
	Scope map[string]string `json:"scope,omitempty"`
}

type managed struct {
	Hash     string `json:"hash"`
	SyncedAt string `json:"synced_at"`
}

func key(harness, skill string) string { return harness + "/" + skill }

func (e Env) lockDir() string   { return e.State + ".lock" }
func (e Env) backupDir() string { return filepath.Join(filepath.Dir(e.State), "backups", "skills") }

func (e Env) load() (state, error) {
	st := state{Schema: Schema, Managed: map[string]managed{}, Off: map[string][]string{}, Scope: map[string]string{}}
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
	if st.Scope == nil {
		st.Scope = map[string]string{}
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

var reName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// ValidName reports whether s can name a skill (and a directory).
func ValidName(s string) bool { return reName.MatchString(s) && !strings.Contains(s, "..") }

// Central lists the central skills: the folders in Central with a SKILL.md.
func (e Env) CentralSkills() ([]string, error) {
	ents, err := os.ReadDir(e.Central)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, d := range ents {
		if !d.IsDir() || !ValidName(d.Name()) {
			continue
		}
		if fi, err := os.Lstat(filepath.Join(e.Central, d.Name(), "SKILL.md")); err == nil && fi.Mode().IsRegular() {
			out = append(out, d.Name())
		}
	}
	sort.Strings(out)
	return out, nil
}

// Hash is a skill folder's content: every regular file's path and bytes.
// A symlink or anything else that isn't a plain file or folder is an
// error, so nothing outside the folder is ever copied or followed.
func Hash(dir string) (string, error) {
	h := sha256.New()
	total := int64(0)
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		switch {
		case d.IsDir():
			return nil
		case !d.Type().IsRegular():
			return fmt.Errorf("%s is not a plain file (symlinks aren't synced)", p)
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		total += fi.Size()
		if total > maxSkillBytes {
			return fmt.Errorf("%s is larger than %d MB", dir, maxSkillBytes>>20)
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		fmt.Fprintf(h, "%s\x00%d\x00", filepath.ToSlash(rel), fi.Size())
		_, err = io.Copy(h, f)
		return err
	})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// exists reports whether p is there (anything, even a broken symlink).
func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// Status is every skill in every CLI.
type Status struct {
	Central  string             `json:"central"`
	Targets  []Target           `json:"targets"`
	Skills   []SkillStatus      `json:"skills"`
	Problems []string           `json:"problems,omitempty"`
	Actions  []Action           `json:"actions"`
	Drift    []DriftInfo        `json:"drift,omitempty"`
	byKey    map[string]*action `json:"-"`
}

// SkillStatus is one skill across the CLIs.
type SkillStatus struct {
	Name    string          `json:"name"`
	Central bool            `json:"central"` // false: only AFK's old copies are left
	Cells   map[string]Cell `json:"cells"`   // by harness
	// Scope is a project skill's scope: project, global, or "" (not
	// chosen yet). Empty for central skills.
	Scope string `json:"scope,omitempty"`
}

// DriftInfo says what changed in a CLI's copy.
type DriftInfo struct {
	Skill    string    `json:"skill"`
	Harness  string    `json:"harness"`
	Modified time.Time `json:"modified"`
}

// Action is one change a sync makes.
type Action struct {
	Kind    string `json:"kind"` // add, update, remove, adopt
	Skill   string `json:"skill"`
	Harness string `json:"harness"`
	Path    string `json:"path"`
}

type action struct {
	Action
	src, hash string
}

// Scan works out each skill's state in each CLI and the sync plan. It
// changes nothing.
func (e Env) Scan(targets []Target) (*Status, error) {
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	return e.scan(st, targets)
}

func (e Env) scan(st state, targets []Target) (*Status, error) {
	names, err := e.CentralSkills()
	if err != nil {
		return nil, err
	}
	s := &Status{Central: e.Central, Targets: targets, Skills: []SkillStatus{}, Actions: []Action{}, byKey: map[string]*action{}}
	hashes := map[string]string{}
	for _, n := range names {
		h, err := Hash(filepath.Join(e.Central, n))
		if err != nil {
			s.Problems = append(s.Problems, err.Error())
			continue
		}
		hashes[n] = h
	}
	// Skills AFK manages somewhere but that are no longer central.
	all := map[string]bool{}
	for _, n := range names {
		all[n] = true
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
	for _, n := range order {
		ch, central := hashes[n]
		ss := SkillStatus{Name: n, Central: central, Cells: map[string]Cell{}}
		// A project skill is only copied once it is scoped to the project;
		// until then (and once global) AFK's old copies are cleaned up as
		// if it were gone.
		copyIt := central
		if e.Ask && central {
			ss.Scope = st.Scope[n]
			copyIt = ss.Scope == ScopeProject
		}
		for _, t := range targets {
			c := e.cell(st, s, t, n, ch, copyIt)
			if central && !copyIt && c == Unmanaged {
				c = Ask
				if ss.Scope == ScopeGlobal {
					c = Global
				}
			}
			ss.Cells[t.Harness] = c
		}
		if !central {
			// Only show a gone skill where AFK still has a copy.
			keep := false
			for _, c := range ss.Cells {
				if c != Unmanaged {
					keep = true
				}
			}
			if !keep {
				continue
			}
		}
		s.Skills = append(s.Skills, ss)
	}
	for _, t := range targets {
		for _, n := range order {
			if a := s.byKey[key(t.Harness, n)]; a != nil {
				s.Actions = append(s.Actions, a.Action)
			}
		}
	}
	return s, nil
}

func (e Env) cell(st state, s *Status, t Target, n, centralHash string, central bool) Cell {
	path := filepath.Join(t.Dir, n)
	m, isManaged := st.Managed[key(t.Harness, n)]
	off := contains(st.Off[n], t.Harness)
	plan := func(kind string) {
		s.byKey[key(t.Harness, n)] = &action{Action: Action{Kind: kind, Skill: n, Harness: t.Harness, Path: path},
			src: filepath.Join(e.Central, n), hash: centralHash}
	}
	if !exists(path) {
		switch {
		case !central:
			return Unmanaged
		case off:
			return Off
		}
		plan("add")
		return Pending
	}
	h, herr := Hash(path)
	if !isManaged {
		if central && herr == nil && h == centralHash && !off {
			plan("adopt") // the same skill, copied by hand: AFK takes it on
			return Pending
		}
		if !central {
			return Unmanaged
		}
		return Conflict // your own skill of that name: never touched
	}
	if herr != nil || h != m.Hash {
		var mod time.Time
		if fi, err := os.Stat(filepath.Join(path, "SKILL.md")); err == nil {
			mod = fi.ModTime()
		}
		s.Drift = append(s.Drift, DriftInfo{Skill: n, Harness: t.Harness, Modified: mod})
		return Drifted
	}
	switch {
	case !central:
		plan("remove")
		return Orphan
	case off:
		plan("remove")
		return Removing
	case h != centralHash:
		plan("update")
		return Pending
	}
	return Synced
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// Result is what a sync did.
type Result struct {
	Done   []Action `json:"done"`
	Backup string   `json:"backup,omitempty"`
}

// Sync makes the plan Scan shows, under the lock. It stops at the first
// failure and puts back every change it made; Result lists what was done
// when it succeeds.
func (e Env) Sync(targets []Target) (*Result, error) {
	lock, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer lock.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	// Scan again under the lock: the plan is what is true now.
	s, err := e.scan(st, targets)
	if err != nil {
		return nil, err
	}
	var acts []*action
	for _, a := range s.Actions {
		acts = append(acts, s.byKey[key(a.Harness, a.Skill)])
	}
	return e.apply(st, acts)
}

func (e Env) lock() (*statefile.Lock, error) {
	if err := os.MkdirAll(filepath.Dir(e.State), 0o700); err != nil {
		return nil, err
	}
	return statefile.Acquire(e.lockDir(), 10*time.Second, 5*time.Minute)
}

// undo is one change to put back.
type undo func() error

// apply makes the actions; on failure it rolls back everything it did.
func (e Env) apply(st state, acts []*action) (*Result, error) {
	res := &Result{}
	if len(acts) == 0 {
		return res, nil
	}
	backup := e.newBackup()
	var undos []undo
	rollback := func(cause error) (*Result, error) {
		for i := len(undos) - 1; i >= 0; i-- {
			if err := undos[i](); err != nil {
				cause = fmt.Errorf("%w; putting it back also failed: %v (the backup is in %s)", cause, err, backup)
			}
		}
		return nil, cause
	}
	for _, a := range acts {
		var u undo
		var err error
		switch a.Kind {
		case "adopt":
			// Nothing to write: the copy is already the central one.
		case "add", "update":
			u, err = place(a.src, a.Path, filepath.Join(backup, a.Harness, a.Skill), a.hash)
		case "remove":
			u, err = remove(a.Path, filepath.Join(backup, a.Harness, a.Skill))
		}
		if u != nil {
			undos = append(undos, u)
		}
		if err != nil {
			return rollback(fmt.Errorf("%s %s in %s: %w", a.Kind, a.Skill, a.Harness, err))
		}
		k := key(a.Harness, a.Skill)
		if a.Kind == "remove" {
			delete(st.Managed, k)
		} else {
			st.Managed[k] = managed{Hash: a.hash, SyncedAt: e.now().UTC().Format(time.RFC3339)}
		}
		res.Done = append(res.Done, a.Action)
	}
	if err := e.save(st); err != nil {
		return rollback(fmt.Errorf("saving %s: %w", e.State, err))
	}
	if exists(backup) {
		res.Backup = backup
	}
	e.pruneBackups(20)
	return res, nil
}

// place copies the central folder src to dst through a temp folder beside
// it. An existing dst is moved to bak first. The copy is checked against
// want before it counts.
func place(src, dst, bak, want string) (undo, error) {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return nil, err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(dst), ".afk-"+filepath.Base(dst)+"-")
	if err != nil {
		return nil, err
	}
	if err := copyDir(src, tmp); err != nil {
		_ = os.RemoveAll(tmp)
		return nil, err
	}
	if h, err := Hash(tmp); err != nil || h != want {
		_ = os.RemoveAll(tmp)
		if err == nil {
			err = errors.New("the copy doesn't match the central skill (was it edited during the sync?)")
		}
		return nil, err
	}
	had := exists(dst)
	if had {
		if err := move(dst, bak); err != nil {
			_ = os.RemoveAll(tmp)
			return nil, err
		}
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.RemoveAll(tmp)
		if had {
			_ = move(bak, dst)
		}
		return nil, err
	}
	return func() error {
		if err := os.RemoveAll(dst); err != nil {
			return err
		}
		if had {
			return move(bak, dst)
		}
		return nil
	}, nil
}

// remove moves dst to bak.
func remove(dst, bak string) (undo, error) {
	if err := move(dst, bak); err != nil {
		return nil, err
	}
	return func() error { return move(bak, dst) }, nil
}

// move renames a folder, copying it when the rename can't cross devices.
func move(from, to string) error {
	if err := os.MkdirAll(filepath.Dir(to), 0o700); err != nil {
		return err
	}
	if err := os.Rename(from, to); err == nil {
		return nil
	}
	if err := copyDir(from, to); err != nil {
		_ = os.RemoveAll(to)
		return err
	}
	return os.RemoveAll(from)
}

// copyDir copies the plain files and folders of src into dst (which may
// exist and be empty). Anything else is an error.
func copyDir(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		out := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(out, 0o755)
		case !d.Type().IsRegular():
			return fmt.Errorf("%s is not a plain file (symlinks aren't synced)", p)
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		f, err := os.OpenFile(out, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, fi.Mode().Perm()|0o600)
		if err != nil {
			return err
		}
		if _, err := io.Copy(f, in); err != nil {
			f.Close()
			return err
		}
		return f.Close()
	})
}

// pruneBackups keeps the newest n backup sets.
// newBackup is a backup folder no earlier change used (it is made only
// when something is backed up).
func (e Env) newBackup() string {
	stamp := e.now().UTC().Format("20060102T150405Z")
	p := filepath.Join(e.backupDir(), stamp)
	for i := 2; exists(p); i++ {
		p = filepath.Join(e.backupDir(), fmt.Sprintf("%s-%d", stamp, i))
	}
	return p
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

// find is the target for a harness.
func find(targets []Target, harness string) (Target, bool) {
	for _, t := range targets {
		if t.Harness == harness {
			return t, true
		}
	}
	return Target{}, false
}

// Keep makes a CLI's edited copy the central one: the central folder is
// backed up and replaced, and the CLI's copy is recorded as synced. The
// other CLIs get it on the next sync.
func (e Env) Keep(targets []Target, skill, harness string) (*Result, error) {
	t, ok := find(targets, harness)
	if !ok || !ValidName(skill) {
		return nil, fmt.Errorf("no skill %s in %s", skill, harness)
	}
	lock, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer lock.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	if _, ok := st.Managed[key(harness, skill)]; !ok {
		return nil, fmt.Errorf("%s in %s isn't a copy AFK synced; copy it into %s yourself to make it central", skill, harness, e.Central)
	}
	src := filepath.Join(t.Dir, skill)
	h, err := Hash(src)
	if err != nil {
		return nil, err
	}
	backup := e.newBackup()
	u, err := place(src, filepath.Join(e.Central, skill), filepath.Join(backup, "central", skill), h)
	if err != nil {
		return nil, err
	}
	st.Managed[key(harness, skill)] = managed{Hash: h, SyncedAt: e.now().UTC().Format(time.RFC3339)}
	if err := e.save(st); err != nil {
		_ = u()
		return nil, err
	}
	res := &Result{Done: []Action{{Kind: "keep", Skill: skill, Harness: harness, Path: filepath.Join(e.Central, skill)}}}
	if exists(backup) {
		res.Backup = backup
	}
	return res, nil
}

// Restore puts the central copy back in a CLI over its edited one (which
// is backed up).
func (e Env) Restore(targets []Target, skill, harness string) (*Result, error) {
	t, ok := find(targets, harness)
	if !ok || !ValidName(skill) {
		return nil, fmt.Errorf("no skill %s in %s", skill, harness)
	}
	lock, err := e.lock()
	if err != nil {
		return nil, err
	}
	defer lock.Release()
	st, err := e.load()
	if err != nil {
		return nil, err
	}
	if _, ok := st.Managed[key(harness, skill)]; !ok {
		return nil, fmt.Errorf("%s in %s isn't a copy AFK synced, so AFK won't replace it", skill, harness)
	}
	src := filepath.Join(e.Central, skill)
	h, err := Hash(src)
	if err != nil {
		return nil, fmt.Errorf("the central %s: %w", skill, err)
	}
	return e.apply(st, []*action{{Action: Action{Kind: "update", Skill: skill, Harness: harness, Path: filepath.Join(t.Dir, skill)}, src: src, hash: h}})
}

// SetEnabled turns a skill on or off for a CLI. Nothing is written into
// the CLI until the next sync.
// SetScope records a project skill's scope (Env.Ask). Sync then copies a
// project-scoped skill into the CLIs' project folders, and removes AFK's
// copies of one made global.
func (e Env) SetScope(skill, scope string) error {
	if !ValidName(skill) {
		return fmt.Errorf("%q is not a skill name", skill)
	}
	if scope != ScopeProject && scope != ScopeGlobal {
		return fmt.Errorf("scope is project or global, not %q", scope)
	}
	lock, err := e.lock()
	if err != nil {
		return err
	}
	defer lock.Release()
	st, err := e.load()
	if err != nil {
		return err
	}
	st.Scope[skill] = scope
	return e.save(st)
}

// CopyInto copies a skill into another skills folder (a project skill
// into the central one, to make it global). It never overwrites: if the
// folder already has a different skill of that name, it says so.
func (e Env) CopyInto(skill, dir string) error {
	if !ValidName(skill) {
		return fmt.Errorf("%q is not a skill name", skill)
	}
	src, dst := filepath.Join(e.Central, skill), filepath.Join(dir, skill)
	h, err := Hash(src)
	if err != nil {
		return err
	}
	if exists(dst) {
		if h2, err := Hash(dst); err == nil && h2 == h {
			return nil // already there
		}
		return fmt.Errorf("%s already has a different skill called %s; rename one of them", dir, skill)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(dir, "."+skill+".afk-")
	if err != nil {
		return err
	}
	if err := copyDir(src, tmp); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	return nil
}

func (e Env) SetEnabled(skill, harness string, on bool) error {
	if !ValidName(skill) {
		return fmt.Errorf("%q is not a skill name", skill)
	}
	lock, err := e.lock()
	if err != nil {
		return err
	}
	defer lock.Release()
	st, err := e.load()
	if err != nil {
		return err
	}
	var off []string
	for _, h := range st.Off[skill] {
		if h != harness {
			off = append(off, h)
		}
	}
	if !on {
		off = append(off, harness)
		sort.Strings(off)
	}
	if len(off) == 0 {
		delete(st.Off, skill)
	} else {
		st.Off[skill] = off
	}
	return e.save(st)
}

// New makes a central skill with a SKILL.md to fill in.
func (e Env) New(name, description string) (string, error) {
	if !ValidName(name) {
		return "", fmt.Errorf("%q is not a skill name (lowercase letters, digits, . _ -)", name)
	}
	dir := filepath.Join(e.Central, name)
	if exists(dir) {
		return "", fmt.Errorf("%s already exists", dir)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	if description == "" {
		description = "When to use this skill."
	}
	body := "---\nname: " + name + "\ndescription: " + description + "\n---\n\n# " + name + "\n\n"
	p := filepath.Join(dir, "SKILL.md")
	return p, os.WriteFile(p, []byte(body), 0o644)
}

// Diff shows how a CLI's copy of a skill differs from the central one,
// file by file, with changed lines marked - (central) and + (the CLI's).
func (e Env) Diff(targets []Target, skill, harness string) (string, error) {
	t, ok := find(targets, harness)
	if !ok || !ValidName(skill) {
		return "", fmt.Errorf("no skill %s in %s", skill, harness)
	}
	a, b := filepath.Join(e.Central, skill), filepath.Join(t.Dir, skill)
	fa, err := files(a)
	if err != nil {
		return "", err
	}
	fb, err := files(b)
	if err != nil {
		return "", err
	}
	names := map[string]bool{}
	for n := range fa {
		names[n] = true
	}
	for n := range fb {
		names[n] = true
	}
	var order []string
	for n := range names {
		order = append(order, n)
	}
	sort.Strings(order)
	var out strings.Builder
	for _, n := range order {
		x, inA := fa[n]
		y, inB := fb[n]
		switch {
		case !inB:
			fmt.Fprintf(&out, "only in central: %s\n", n)
		case !inA:
			fmt.Fprintf(&out, "only in %s: %s\n", harness, n)
		case x != y:
			fmt.Fprintf(&out, "--- central/%s/%s\n+++ %s/%s/%s\n", skill, n, harness, skill, n)
			out.WriteString(lineDiff(x, y))
		}
	}
	if out.Len() == 0 {
		return "no differences\n", nil
	}
	return out.String(), nil
}

// files reads a skill folder's plain files (text up to the size bound).
func files(dir string) (map[string]string, error) {
	out := map[string]string{}
	if !exists(dir) {
		return out, nil
	}
	if _, err := Hash(dir); err != nil {
		return nil, err
	}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		out[filepath.ToSlash(rel)] = string(b)
		return nil
	})
	return out, err
}

// lineDiff marks the lines that differ, from a longest common
// subsequence of the two files' lines.
func lineDiff(a, b string) string {
	x, y := strings.Split(a, "\n"), strings.Split(b, "\n")
	if len(x)*len(y) > 4_000_000 {
		return fmt.Sprintf("  (%d and %d lines; too long to compare line by line)\n", len(x), len(y))
	}
	n, m := len(x), len(y)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if x[i] == y[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	var out strings.Builder
	i, j := 0, 0
	for i < n || j < m {
		switch {
		case i < n && j < m && x[i] == y[j]:
			i++
			j++
		case i < n && (j == m || lcs[i+1][j] >= lcs[i][j+1]):
			out.WriteString("- " + x[i] + "\n")
			i++
		default:
			out.WriteString("+ " + y[j] + "\n")
			j++
		}
	}
	return out.String()
}

// Changed counts the lines that differ between a CLI's copy and central.
func (e Env) Changed(targets []Target, skill, harness string) int {
	d, err := e.Diff(targets, skill, harness)
	if err != nil {
		return 0
	}
	n := 0
	for _, l := range strings.Split(d, "\n") {
		if strings.HasPrefix(l, "+ ") || strings.HasPrefix(l, "- ") || strings.HasPrefix(l, "only in") {
			n++
		}
	}
	return n
}
