package config

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"

	toml "github.com/pelletier/go-toml/v2"

	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// LockVersion is the afk.lock format version.
const LockVersion = 1

// Lock is afk.lock: everything AFK installed, so a setup can be
// reproduced on another machine and an install undone exactly. Installers
// write it; nothing in this version of AFK installs yet.
type Lock struct {
	Version  int       `toml:"version"`
	Installs []Install `toml:"install"`
}

// Install is one installed item.
type Install struct {
	Name    string `toml:"name"`
	Kind    string `toml:"kind"` // skill, mcp, tool or harness
	Version string `toml:"version"`
	// Source is where it came from, pinned: npm:pkg@1.2.3,
	// github:owner/repo@<commit>, or a local path.
	Source string `toml:"source"`
	// Integrity is the hash of what was installed: sha256-<base64> or
	// sha512-<base64>, as npm writes it.
	Integrity string `toml:"integrity"`
	// Harnesses are the CLIs it was written into.
	Harnesses   []string  `toml:"harnesses"`
	InstalledAt time.Time `toml:"installed_at"`
}

// LockKinds are the kinds of installs.
var LockKinds = []string{"skill", "mcp", "tool", "harness"}

var integrityRE = regexp.MustCompile(`^sha(256|384|512)-[A-Za-z0-9+/]+=*$`)

// ReadLock reads afk.lock; a missing file is an empty lock.
func ReadLock(path string) (*Lock, error) {
	l := &Lock{Version: LockVersion}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return l, nil
	}
	if err != nil {
		return nil, err
	}
	dec := toml.NewDecoder(bytes.NewReader(b)).DisallowUnknownFields()
	if err := dec.Decode(l); err != nil {
		var de *toml.DecodeError
		if errors.As(err, &de) {
			row, _ := de.Position()
			return nil, Problem{File: path, Line: row, Msg: de.Error()}
		}
		var sm *toml.StrictMissingError
		if errors.As(err, &sm) && len(sm.Errors) > 0 {
			row, _ := sm.Errors[0].Position()
			return nil, Problem{File: path, Line: row, Msg: "unknown field in afk.lock (written by a newer afk?)"}
		}
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := l.Validate(path); err != nil {
		return nil, err
	}
	return l, nil
}

// Validate checks every entry.
func (l *Lock) Validate(path string) error {
	if l.Version != LockVersion {
		return Problem{File: path, Key: "version", Msg: fmt.Sprintf("this afk reads afk.lock version %d, not %d", LockVersion, l.Version)}
	}
	seen := map[string]bool{}
	var probs Errors
	for i, in := range l.Installs {
		key := fmt.Sprintf("install[%d]", i)
		bad := func(msg string) { probs = append(probs, Problem{File: path, Key: key, Msg: msg}) }
		switch {
		case in.Name == "":
			bad("needs a name")
		case !contains(LockKinds, in.Kind):
			bad(fmt.Sprintf("kind %q is not one of skill, mcp, tool, harness", in.Kind))
		case in.Source == "":
			bad("needs a source")
		case !integrityRE.MatchString(in.Integrity):
			bad("integrity must be sha256-, sha384- or sha512- followed by base64")
		case seen[in.Kind+"/"+in.Name]:
			bad(in.Kind + " " + in.Name + " is listed twice")
		}
		seen[in.Kind+"/"+in.Name] = true
	}
	if len(probs) > 0 {
		return probs
	}
	return nil
}

// Put adds an install, or replaces the one of the same kind and name.
func (l *Lock) Put(in Install) {
	for i, x := range l.Installs {
		if x.Kind == in.Kind && x.Name == in.Name {
			l.Installs[i] = in
			return
		}
	}
	l.Installs = append(l.Installs, in)
}

// Remove drops an install; it reports whether there was one.
func (l *Lock) Remove(kind, name string) bool {
	for i, x := range l.Installs {
		if x.Kind == kind && x.Name == name {
			l.Installs = append(l.Installs[:i], l.Installs[i+1:]...)
			return true
		}
	}
	return false
}

const lockHeader = "# afk.lock: what AFK installed. Written by afk; don't edit by hand.\n"

// WriteLock writes afk.lock atomically, under its lock, sorted by kind
// and name so the file diffs cleanly.
func WriteLock(path string, l *Lock) error {
	l.Version = LockVersion
	if err := l.Validate(path); err != nil {
		return err
	}
	sort.SliceStable(l.Installs, func(i, j int) bool {
		a, b := l.Installs[i], l.Installs[j]
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		return a.Name < b.Name
	})
	body, err := toml.Marshal(l)
	if err != nil {
		return err
	}
	return writeLocked(path, append([]byte(lockHeader), body...))
}

// writeLocked replaces a file atomically while holding its mkdir lock
// (the same lock AFK takes for its state files).
func writeLocked(path string, b []byte) error {
	return writeLockedWait(path, b, 10*time.Second)
}

func writeLockedWait(path string, b []byte, wait time.Duration) error {
	return withLockWait(path, wait, func() error { return statefile.WriteFile(path, b) })
}

// withLock runs fn while holding path's mkdir lock, so a whole
// read-modify-write is one step for every writer. The lock is not
// re-entrant: fn must write with statefile.WriteFile, not writeLocked.
func withLock(path string, fn func() error) error {
	return withLockWait(path, 10*time.Second, fn)
}

func withLockWait(path string, wait time.Duration, fn func() error) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	lk, err := statefile.Acquire(path+".lock", wait, 10*time.Second)
	if err != nil {
		return err
	}
	defer lk.Release()
	return fn()
}
