// Package statefile reads and writes AFK's small state files (pool
// signals, the benchmark catalog): a mkdir lock around a read-modify-write,
// and an atomic rename into place. The lock is the one the old bash engine
// took, so an older install sharing the files still respects it.
package statefile

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// Lock is a held mkdir lock.
type Lock struct {
	dir   string
	token string
}

// ErrBusy is a lock another writer still holds after the wait.
var ErrBusy = errors.New("the state file is locked by another writer")

// Acquire takes the mkdir lock at dir (the bash engine's _afk_router_lock).
// Writers hold it for milliseconds, so a lock older than stale belongs to a
// killed writer and is taken over; taking over is itself serialized through
// dir+".reap", so two waiters never both remove it. It waits up to wait.
func Acquire(dir string, wait, stale time.Duration) (*Lock, error) {
	deadline := time.Now().Add(wait)
	token := newToken()
	for {
		err := os.Mkdir(dir, 0o755)
		if err == nil {
			_ = os.WriteFile(filepath.Join(dir, "owner"), []byte(token+"\n"), 0o644)
			return &Lock{dir: dir, token: token}, nil
		}
		if !os.IsExist(err) {
			// A missing or read-only parent: there is no lock to wait for.
			return nil, err
		}
		if fi, serr := os.Stat(dir); serr == nil && old(fi.ModTime(), stale) {
			if os.Mkdir(dir+".reap", 0o755) == nil {
				if fi, err := os.Stat(dir); err == nil && old(fi.ModTime(), stale) {
					_ = os.RemoveAll(dir)
				}
				_ = os.Remove(dir + ".reap")
				continue
			}
			// Another waiter is taking over; a reap lock left by a killed
			// waiter is cleared once it is stale itself.
			if fi, err := os.Stat(dir + ".reap"); err == nil && old(fi.ModTime(), stale) {
				_ = os.Remove(dir + ".reap")
			}
		}
		if time.Now().After(deadline) {
			return nil, ErrBusy
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// old: older than stale, or dated more than a minute in the future (a lock
// from a skewed clock must not hold the file for good).
func old(t time.Time, stale time.Duration) bool {
	now := time.Now()
	return now.Sub(t) >= stale || t.After(now.Add(time.Minute))
}

// Release drops the lock, only if this writer still holds it.
func (l *Lock) Release() {
	if l == nil {
		return
	}
	held, _ := os.ReadFile(filepath.Join(l.dir, "owner"))
	h := string(bytes.TrimSpace(held))
	if h == "" || h == l.token {
		_ = os.Remove(filepath.Join(l.dir, "owner"))
		_ = os.Remove(l.dir)
	}
}

func newToken() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// WriteJSON writes a JSON document to dest through a uniquely named temp
// file beside it and renames it into place, keeping dest's mode (0644 for
// a new file). Invalid or empty JSON never replaces dest and leaves no temp
// file.
func WriteJSON(dest string, doc []byte) error {
	if len(bytes.TrimSpace(doc)) == 0 || !json.Valid(doc) {
		return errors.New("refusing to write invalid JSON to " + dest)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	mode := os.FileMode(0o644)
	if fi, err := os.Stat(dest); err == nil {
		mode = fi.Mode().Perm()
	}
	f, err := os.CreateTemp(filepath.Dir(dest), filepath.Base(dest)+".tmp.*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(doc)
	cerr := f.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmp, mode)
	}
	if werr == nil {
		werr = os.Rename(tmp, dest)
	}
	if werr != nil {
		_ = os.Remove(tmp)
	}
	return werr
}
