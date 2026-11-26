package config

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	toml "github.com/pelletier/go-toml/v2"
)

// Paths are where AFK keeps its files.
type Paths struct {
	Dir    string // the config directory: $XDG_CONFIG_HOME/afk or ~/.config/afk
	Config string // config.toml
	Lock   string // afk.lock
	State  string // runtime state: $XDG_STATE_HOME/afk or ~/.local/state/afk
	// Legacy is ~/.config/afk/router.json, read while config.toml is absent.
	Legacy string
}

// PathsFor works out the paths for a home directory and environment.
func PathsFor(home string, getenv func(string) string) Paths {
	if getenv == nil {
		getenv = func(string) string { return "" }
	}
	cfg := getenv("XDG_CONFIG_HOME")
	if cfg == "" || !filepath.IsAbs(cfg) {
		cfg = filepath.Join(home, ".config")
	}
	state := getenv("XDG_STATE_HOME")
	if state == "" || !filepath.IsAbs(state) {
		state = filepath.Join(home, ".local", "state")
	}
	dir := filepath.Join(cfg, "afk")
	if p := getenv("AFK_CONFIG"); p != "" {
		dir = filepath.Dir(p)
	}
	conf := filepath.Join(dir, "config.toml")
	if p := getenv("AFK_CONFIG"); p != "" {
		conf = p
	}
	return Paths{
		Dir: dir, Config: conf, Lock: filepath.Join(dir, "afk.lock"),
		State: filepath.Join(state, "afk"),
		// The caches and router.json have always lived under ~/.config/afk,
		// whatever XDG_CONFIG_HOME says.
		Legacy: filepath.Join(home, ".config", "afk", "router.json"),
	}
}

// File is a loaded config.toml.
type File struct {
	Config
	Path   string
	Exists bool
	Raw    []byte
	// Warnings are keys AFK doesn't know (they are ignored).
	Warnings []Problem
	lines    map[string]int
}

// Load reads config.toml. A missing file is an empty config, version 1.
// Unknown keys are warnings; a value of the wrong type, a bad value or
// TOML that doesn't parse is an error naming the file, line and key.
func Load(path string) (*File, error) {
	f := &File{Path: path, Config: Config{Version: Version}}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return f, nil
	}
	if err != nil {
		return nil, err
	}
	f.Exists, f.Raw = true, b
	if err := f.parse(); err != nil {
		return nil, err
	}
	return f, nil
}

// Parse reads a config.toml document from memory.
func Parse(path string, b []byte) (*File, error) {
	f := &File{Path: path, Exists: true, Raw: b}
	if err := f.parse(); err != nil {
		return nil, err
	}
	return f, nil
}

func (f *File) parse() error {
	entries, err := scan(f.Raw)
	if err != nil {
		return syntaxError(f.Path, f.Raw, err)
	}
	f.lines = lines(entries)
	var c Config
	strict := toml.NewDecoder(bytes.NewReader(f.Raw)).DisallowUnknownFields()
	err = strict.Decode(&c)
	var sm *toml.StrictMissingError
	if errors.As(err, &sm) {
		for _, e := range sm.Errors {
			row, _ := e.Position()
			f.Warnings = append(f.Warnings, Problem{File: f.Path, Line: row, Key: strings.Join(e.Key(), "."), Msg: "not a config key; ignored"})
		}
		c = Config{}
		err = toml.NewDecoder(bytes.NewReader(f.Raw)).Decode(&c)
	}
	if err != nil {
		var de *toml.DecodeError
		if errors.As(err, &de) {
			row, _ := de.Position()
			return Problem{File: f.Path, Line: row, Key: strings.Join(de.Key(), "."), Msg: de.Error()}
		}
		return fmt.Errorf("%s: %w", f.Path, err)
	}
	if _, set := f.lines["version"]; !set {
		// Missing: taken as this version, with a warning. An explicit
		// version = 0 is not missing, and validation refuses it.
		f.Warnings = append(f.Warnings, Problem{File: f.Path, Line: 1, Key: "version", Msg: fmt.Sprintf("missing; taken as %d (add version = %d)", Version, Version)})
		c.Version = Version
	}
	f.Config = c
	if probs := c.validate(f.Path, f.lines); len(probs) > 0 {
		return Errors(probs)
	}
	return nil
}

// syntaxError reports TOML that doesn't parse, with the line: the
// decoder's error has it.
func syntaxError(path string, raw []byte, err error) error {
	var m map[string]any
	var de *toml.DecodeError
	if derr := toml.Unmarshal(raw, &m); errors.As(derr, &de) {
		row, _ := de.Position()
		return Problem{File: path, Line: row, Key: strings.Join(de.Key(), "."), Msg: "not valid TOML: " + de.Error()}
	}
	return Problem{File: path, Key: "(document)", Msg: "not valid TOML: " + err.Error()}
}

// Errors is several validation problems.
type Errors []Problem

func (e Errors) Error() string {
	var s []string
	for _, p := range e {
		s = append(s, p.String())
	}
	return strings.Join(s, "\n")
}

// Defaults are the values of the scalar keys when config.toml doesn't set
// them.
var Defaults = map[string]any{
	"version":                    Version,
	"route.prefer":               "balanced",
	"route.prefer_free":          false,
	"route.allow_metered":        false,
	"route.allow_free_reviewers": false,
	"permissions.default":        "ask",
	"bench.autosync":             true,
}

// Get looks a key up in config.toml: its value, and whether config.toml
// set it (else the default, or nil). A table comes back whole. A secret is
// only ever a reference here; Get resolves nothing.
func (f *File) Get(key string) (any, bool, error) {
	var m map[string]any
	if f.Exists {
		if err := toml.Unmarshal(f.Raw, &m); err != nil {
			return nil, false, err
		}
	}
	var cur any = m
	for _, part := range strings.Split(key, ".") {
		mm, ok := cur.(map[string]any)
		if !ok {
			cur = nil
			break
		}
		cur, ok = mm[part]
		if !ok {
			cur = nil
			break
		}
	}
	if cur != nil {
		return cur, true, nil
	}
	if d, ok := Defaults[key]; ok {
		return d, false, nil
	}
	if KeyType(key) == "" {
		return nil, false, fmt.Errorf("%s is not a config key", key)
	}
	return nil, false, nil
}
