// Package apikey is AFK's own API keys: the keys a gateway (LiteLLM, any
// OpenAI- or Anthropic-compatible client) uses to call afk serve.
//
// There are two kinds. A router key reaches the model names afk/auto and
// afk/<task>: AFK picks the harness and model from the benchmarks, the
// way afk -p does. A harness key is locked to one harness (grok, codex,
// ...): the caller names a model that harness serves, or its default, and
// AFK makes no routing decision.
//
// Only a SHA-256 hash of each key is stored, in a 0600 file in AFK's
// state directory, never in config.toml. The key itself is shown once,
// when it is made or rotated. Every key starts with rate limits turned
// on; each limit can be changed or turned off per key.
package apikey

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/statefile"
)

// Schema is the keys file's schema.
const Schema = "afk-keys/1"

// The kinds of key.
const (
	KindRouter  = "router"
	KindHarness = "harness"
)

// Limits are a key's rate limits. Zero turns a limit off.
type Limits struct {
	// PerMinute and PerDay count requests that were let through, over
	// the last 60 seconds and the last 24 hours.
	PerMinute int `json:"per_minute"`
	PerDay    int `json:"per_day"`
	// Concurrent is how many runs may go at once.
	Concurrent int `json:"concurrent"`
}

// MaxLimit is the largest count a limit takes.
const MaxLimit = 1000000

// Off reports whether every limit is off.
func (l Limits) Off() bool { return l.PerMinute == 0 && l.PerDay == 0 && l.Concurrent == 0 }

func (l Limits) String() string {
	part := func(n int, unit string) string {
		if n == 0 {
			return "no " + unit + " limit"
		}
		return fmt.Sprintf("%d %s", n, unit)
	}
	if l.Off() {
		return "no limits"
	}
	return part(l.PerMinute, "/min") + " · " + part(l.PerDay, "/day") + " · " + part(l.Concurrent, "at once")
}

// DefaultLimits are what a new key starts with: about what one person
// working by hand sends, so a script or a shared key can't run a plan
// into the ground (or into a vendor's abuse checks) by accident. A harness
// key reaches one subscription, so it starts lower.
func DefaultLimits(kind string) Limits {
	if kind == KindHarness {
		return Limits{PerMinute: 6, PerDay: 200, Concurrent: 1}
	}
	return Limits{PerMinute: 10, PerDay: 500, Concurrent: 2}
}

// Key is one key, as stored: everything but the secret.
type Key struct {
	// ID is the key's public part, the second field of the key itself.
	ID   string `json:"id"`
	Name string `json:"name"`
	Kind string `json:"kind"`
	// Harness is the one harness a harness key reaches.
	Harness string `json:"harness,omitempty"`
	// Models, when set, are the only models a harness key may name.
	Models []string `json:"models,omitempty"`
	// Hash is the hex SHA-256 of the whole key.
	Hash   string `json:"hash"`
	Limits Limits `json:"limits"`
	// Dir is the folder runs work in; "" is a new empty folder per call,
	// removed afterwards. Mode is the permission mode ("" is read-only).
	Dir  string `json:"dir,omitempty"`
	Mode string `json:"mode,omitempty"`

	Created time.Time  `json:"created"`
	Rotated *time.Time `json:"rotated,omitempty"`
	Revoked *time.Time `json:"revoked,omitempty"`
}

// Active reports whether the key still works.
func (k Key) Active() bool { return k.Revoked == nil }

// RunMode is the permission mode a call through the key runs in.
func (k Key) RunMode() string {
	if k.Mode == "" {
		return "read-only"
	}
	return k.Mode
}

// Hint is how the key is shown: its prefix and id, never its secret.
func (k Key) Hint() string { return prefix + k.ID + "_…" }

type file struct {
	Schema string `json:"schema"`
	Keys   []Key  `json:"keys"`
}

// Store is the keys file.
type Store struct {
	Path string
	Now  func() time.Time
}

// PathFor is the keys file in AFK's state directory (AFK_KEYS_FILE wins).
func PathFor(stateDir string, getenv func(string) string) string {
	if getenv != nil {
		if p := getenv("AFK_KEYS_FILE"); p != "" {
			return p
		}
	}
	return filepath.Join(stateDir, "keys.json")
}

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// List is every key, active and revoked, by name.
func (s *Store) List() ([]Key, error) {
	f, err := s.read()
	if err != nil {
		return nil, err
	}
	sort.Slice(f.Keys, func(i, j int) bool { return f.Keys[i].Name < f.Keys[j].Name })
	return f.Keys, nil
}

// Get is the key with this name or id.
func (s *Store) Get(ref string) (Key, error) {
	f, err := s.read()
	if err != nil {
		return Key{}, err
	}
	i := find(f.Keys, ref)
	if i < 0 {
		return Key{}, fmt.Errorf("no key called %s", ref)
	}
	return f.Keys[i], nil
}

func (s *Store) read() (file, error) {
	b, err := os.ReadFile(s.Path)
	if errors.Is(err, os.ErrNotExist) {
		return file{Schema: Schema}, nil
	}
	if err != nil {
		return file{}, err
	}
	var f file
	if err := json.Unmarshal(b, &f); err != nil {
		return file{}, fmt.Errorf("%s: %w", s.Path, err)
	}
	if f.Schema != Schema {
		return file{}, fmt.Errorf("%s is %q, this AFK reads %s", s.Path, f.Schema, Schema)
	}
	return f, nil
}

// change reads the file, lets fn change it and writes it back, under the
// state lock.
func (s *Store) change(fn func(*file) error) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	lock, err := statefile.Acquire(s.Path+".lock", 5*time.Second, 30*time.Second)
	if err != nil {
		return err
	}
	defer lock.Release()
	f, err := s.read()
	if err != nil {
		return err
	}
	if err := fn(&f); err != nil {
		return err
	}
	f.Schema = Schema
	b, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(s.Path, append(b, '\n'))
}

func writePrivate(path string, b []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".keys-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func find(keys []Key, ref string) int {
	for i, k := range keys {
		if k.Name == ref || k.ID == ref {
			return i
		}
	}
	return -1
}

// NameRE is what a key's name may be.
var NameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,39}$`)

// New is a key to make.
type New struct {
	Name    string
	Kind    string
	Harness string
	Models  []string
	// Limits nil starts the key at DefaultLimits.
	Limits *Limits
	Dir    string
	Mode   string
}

// Create makes a key and returns it with the key itself, which is not
// stored and can't be shown again.
func (s *Store) Create(n New) (Key, string, error) {
	if !NameRE.MatchString(n.Name) {
		return Key{}, "", errors.New("a key name is lower-case letters, digits, - or _ (at most 40)")
	}
	switch n.Kind {
	case KindRouter:
		if n.Harness != "" || len(n.Models) > 0 {
			return Key{}, "", errors.New("a router key reaches afk/auto and afk/<task>; a key for one harness is --harness")
		}
	case KindHarness:
		if n.Harness == "" {
			return Key{}, "", errors.New("a harness key needs its harness")
		}
	default:
		return Key{}, "", fmt.Errorf("a key is a %s or a %s key", KindRouter, KindHarness)
	}
	if err := checkRun(n.Dir, n.Mode); err != nil {
		return Key{}, "", err
	}
	if err := checkModels(n.Models); err != nil {
		return Key{}, "", err
	}
	lim := DefaultLimits(n.Kind)
	if n.Limits != nil {
		lim = *n.Limits
	}
	if err := checkLimits(lim); err != nil {
		return Key{}, "", err
	}
	var k Key
	var token string
	err := s.change(func(f *file) error {
		if find(f.Keys, n.Name) >= 0 {
			return fmt.Errorf("there is already a key called %s; rotate it or pick another name", n.Name)
		}
		id, secret, err := newToken(f.Keys)
		if err != nil {
			return err
		}
		token = secret
		k = Key{ID: id, Name: n.Name, Kind: n.Kind, Harness: n.Harness, Models: n.Models, Hash: hash(token), Limits: lim, Dir: n.Dir, Mode: n.Mode, Created: s.now().UTC()}
		f.Keys = append(f.Keys, k)
		return nil
	})
	return k, token, err
}

// Rotate gives the key a new secret and returns it; the old one stops
// working at once. A revoked key comes back to life.
func (s *Store) Rotate(ref string) (Key, string, error) {
	var k Key
	var token string
	err := s.change(func(f *file) error {
		i := find(f.Keys, ref)
		if i < 0 {
			return fmt.Errorf("no key called %s", ref)
		}
		id, secret, err := newToken(f.Keys)
		if err != nil {
			return err
		}
		now := s.now().UTC()
		token = secret
		f.Keys[i].ID, f.Keys[i].Hash, f.Keys[i].Rotated, f.Keys[i].Revoked = id, hash(token), &now, nil
		k = f.Keys[i]
		return nil
	})
	return k, token, err
}

// Revoke stops the key working and keeps its record.
func (s *Store) Revoke(ref string) (Key, error) {
	return s.update(ref, func(k *Key) error {
		if k.Revoked == nil {
			now := s.now().UTC()
			k.Revoked = &now
		}
		return nil
	})
}

// Delete takes the key out of the file.
func (s *Store) Delete(ref string) error {
	return s.change(func(f *file) error {
		i := find(f.Keys, ref)
		if i < 0 {
			return fmt.Errorf("no key called %s", ref)
		}
		f.Keys = append(f.Keys[:i], f.Keys[i+1:]...)
		return nil
	})
}

// SetLimits changes a key's limits.
func (s *Store) SetLimits(ref string, l Limits) (Key, error) {
	if err := checkLimits(l); err != nil {
		return Key{}, err
	}
	return s.update(ref, func(k *Key) error { k.Limits = l; return nil })
}

// SetModels changes the models a harness key may name (none: all).
func (s *Store) SetModels(ref string, models []string) (Key, error) {
	if err := checkModels(models); err != nil {
		return Key{}, err
	}
	return s.update(ref, func(k *Key) error {
		if k.Kind != KindHarness && len(models) > 0 {
			return errors.New("only a harness key has a model list")
		}
		k.Models = models
		return nil
	})
}

// SetRun changes where a key's runs work and in which mode.
func (s *Store) SetRun(ref, dir, mode string) (Key, error) {
	if err := checkRun(dir, mode); err != nil {
		return Key{}, err
	}
	return s.update(ref, func(k *Key) error { k.Dir, k.Mode = dir, mode; return nil })
}

func (s *Store) update(ref string, fn func(*Key) error) (Key, error) {
	var k Key
	err := s.change(func(f *file) error {
		i := find(f.Keys, ref)
		if i < 0 {
			return fmt.Errorf("no key called %s", ref)
		}
		if err := fn(&f.Keys[i]); err != nil {
			return err
		}
		k = f.Keys[i]
		return nil
	})
	return k, err
}

// RunModes are the modes a key's runs may use. A call has no terminal to
// ask in, so "ask" is left out; yolo still needs a folder you trust, as
// afk -p does.
var RunModes = []string{"read-only", "edits", "auto", "yolo"}

func checkRun(dir, mode string) error {
	if mode != "" {
		ok := false
		for _, m := range RunModes {
			ok = ok || m == mode
		}
		if !ok {
			return fmt.Errorf("a key's mode is one of %s", strings.Join(RunModes, ", "))
		}
	}
	if dir == "" {
		if mode != "" && mode != "read-only" {
			return errors.New("a mode that can change files needs a folder (--dir); the default empty folder is thrown away after each call")
		}
		return nil
	}
	if !filepath.IsAbs(dir) {
		return errors.New("the folder must be an absolute path")
	}
	fi, err := os.Stat(dir)
	if err != nil || !fi.IsDir() {
		return fmt.Errorf("%s is not a folder here", dir)
	}
	return nil
}

var modelRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,127}$`)

func checkModels(models []string) error {
	for _, m := range models {
		if !modelRE.MatchString(m) {
			return fmt.Errorf("%q is not a model name", m)
		}
	}
	return nil
}

func checkLimits(l Limits) error {
	if l.PerMinute < 0 || l.PerDay < 0 || l.Concurrent < 0 {
		return errors.New("a limit is a count, or 0 for off")
	}
	if l.PerMinute > MaxLimit || l.PerDay > MaxLimit || l.Concurrent > MaxLimit {
		return fmt.Errorf("a limit is at most %d; 0 turns it off", MaxLimit)
	}
	return nil
}

// Verify finds the active key that token is. The secret is compared in
// constant time.
func (s *Store) Verify(token string) (Key, bool) {
	id, ok := idOf(token)
	if !ok {
		return Key{}, false
	}
	f, err := s.read()
	if err != nil {
		return Key{}, false
	}
	want := hash(token)
	for _, k := range f.Keys {
		if k.ID == id && subtle.ConstantTimeCompare([]byte(k.Hash), []byte(want)) == 1 {
			return k, k.Active()
		}
	}
	return Key{}, false
}

// A key is afk_<id>_<secret>: id is 8 hex digits (public, it names the
// key in logs), secret 64.
const prefix = "afk_"

var tokenRE = regexp.MustCompile(`^afk_([0-9a-f]{8})_[0-9a-f]{64}$`)

func idOf(token string) (string, bool) {
	m := tokenRE.FindStringSubmatch(token)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// LooksLikeKey reports whether s has the shape of an AFK key.
func LooksLikeKey(s string) bool { _, ok := idOf(s); return ok }

func newToken(taken []Key) (id, token string, err error) {
	for range 16 {
		b := make([]byte, 36)
		if _, err := rand.Read(b); err != nil {
			return "", "", err
		}
		id = hex.EncodeToString(b[:4])
		if find(taken, id) >= 0 {
			continue
		}
		return id, prefix + id + "_" + hex.EncodeToString(b[4:]), nil
	}
	return "", "", errors.New("could not pick a free key id")
}

func hash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
