// Package runrec writes the afk-run/1 record of each session to
// ~/.config/afk/state/runs/<id>.json.
package runrec

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// Schema is the run record version.
const Schema = "afk-run/1"

// Outcomes a rating may record.
const (
	Solved    = "solved"
	Partly    = "partly"
	WrongPick = "wrong-pick"
)

// Record is one session. Pointer fields are null when not known.
type Record struct {
	Schema       string       `json:"schema"`
	ID           string       `json:"id"`
	StartedAt    string       `json:"started_at"`
	EndedAt      string       `json:"ended_at"`
	Where        string       `json:"where"`
	Route        engine.Route `json:"route"`
	Exit         int          `json:"exit"`
	DurationS    int64        `json:"duration_s"`
	PoolBefore   *int         `json:"pool_before"`
	PoolAfter    *int         `json:"pool_after"`
	FilesChanged *int         `json:"files_changed"`
	Commits      *int         `json:"commits"`
	Outcome      *string      `json:"outcome"`
}

// Dir is where run records live: $XDG_CONFIG_HOME/afk/state/runs, or
// ~/.config/afk/state/runs.
func Dir() (string, error) {
	if os.Getenv("XDG_CONFIG_HOME") != "" {
		return DirFor("", os.Getenv), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return DirFor(home, os.Getenv), nil
}

// DirFor is Dir for a given home directory and environment.
func DirFor(home string, getenv func(string) string) string {
	base := ""
	if getenv != nil {
		base = getenv("XDG_CONFIG_HOME")
	}
	if base == "" {
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "afk", "state", "runs")
}

// MaxLoad is how many of the newest run records Load reads at most.
const MaxLoad = 5000

// Load reads the run records in dir that ended at or after since, newest
// first (by file time). Placeholders, records of another schema and files
// that don't decode are skipped. A missing dir is no records.
func Load(dir string, since time.Time) []Record {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	type file struct {
		name string
		mod  time.Time
	}
	var files []file
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasPrefix(n, "r-") || !strings.HasSuffix(n, ".json") {
			continue
		}
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.ModTime().Before(since) {
			continue
		}
		files = append(files, file{n, info.ModTime()})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.After(files[j].mod) })
	if len(files) > MaxLoad {
		files = files[:MaxLoad]
	}
	var out []Record
	for _, f := range files {
		b, err := os.ReadFile(filepath.Join(dir, f.name))
		if err != nil {
			continue
		}
		var r Record
		if json.Unmarshal(b, &r) != nil || r.Schema != Schema {
			continue
		}
		if t, err := time.Parse(time.RFC3339, r.EndedAt); err == nil && t.Before(since) {
			continue
		}
		out = append(out, r)
	}
	return out
}

// Reserve picks a run id like r-7f3c and claims it in dir at once (an
// empty <id>.json created with O_EXCL), so two sessions starting together
// never share one. The record written later replaces the placeholder.
func Reserve(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	for n := 2; n <= 8; n++ {
		for try := 0; try < 8; try++ {
			b := make([]byte, n)
			if _, err := rand.Read(b); err != nil {
				return "", err
			}
			id := "r-" + hex.EncodeToString(b)
			f, err := os.OpenFile(filepath.Join(dir, id+".json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
			if errors.Is(err, os.ErrExist) {
				continue
			}
			if err != nil {
				return "", err
			}
			f.Close()
			return id, nil
		}
	}
	return "", errors.New("no free run id")
}

// Fallback is an id for a session whose record cannot be saved.
func Fallback() string { return fmt.Sprintf("r-%x", time.Now().UnixNano()&0xffffff) }

// Write saves the record atomically, readable only by the user.
func Write(dir string, r Record) (string, error) {
	if r.Schema == "" {
		r.Schema = Schema
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	b = append(b, '\n')
	path := filepath.Join(dir, r.ID+".json")
	tmp, err := os.CreateTemp(dir, "."+r.ID+".*.tmp")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return "", err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return "", err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return path, nil
}

// Stamp formats a time for the record.
func Stamp(t time.Time) string { return t.UTC().Format(time.RFC3339) }
