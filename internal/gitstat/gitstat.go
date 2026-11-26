// Package gitstat measures what a session changed in the git repository it
// ran in: files changed and commits made. It only reads; it never writes to
// the repository.
package gitstat

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// maxHashed caps how many already-dirty files are fingerprinted up front.
const maxHashed = 500

// Snapshot is the repository state before a session.
type Snapshot struct {
	Dir   string            // top of the work tree once the snapshot is OK
	Head  string            // HEAD commit, "" on an unborn branch
	Dirty map[string]string // path -> content hash of files dirty before
	ok    bool
}

// Change is what the session changed. Nil fields are unknown.
type Change struct {
	Files   *int
	Commits *int
}

// quiet turns off the setting in a repository's own .git/config that makes
// a read-only git command run a program: afk looks at a directory before
// anyone has said they trust it.
var quiet = []string{"-c", "core.fsmonitor=false"}

func git(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", append(append([]string{"-C", dir, "--no-optional-locks"}, quiet...), args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), err
}

func ctx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}

// Take records the state of the repository at dir. Outside a repository
// (or without git) the snapshot reports nothing.
func Take(dir string) Snapshot {
	c, cancel := ctx()
	defer cancel()
	s := Snapshot{Dir: dir, Dirty: map[string]string{}}
	if out, err := git(c, dir, "rev-parse", "--is-inside-work-tree"); err != nil || strings.TrimSpace(out) != "true" {
		return s
	}
	// git status lists paths from the top of the work tree, so everything
	// below works from there, whichever subdirectory afk started in.
	if out, err := git(c, dir, "rev-parse", "--show-toplevel"); err == nil && strings.TrimSpace(out) != "" {
		dir = strings.TrimSpace(out)
		s.Dir = dir
	}
	if out, err := git(c, dir, "rev-parse", "--verify", "-q", "HEAD"); err == nil {
		s.Head = strings.TrimSpace(out)
	}
	paths, err := dirty(c, dir)
	if err != nil {
		return s
	}
	if len(paths) > maxHashed {
		return s
	}
	hashes, err := hashFiles(c, dir, paths)
	if err != nil {
		return s
	}
	s.Dirty = hashes
	s.ok = true
	return s
}

// OK reports whether the snapshot is from a repository.
func (s Snapshot) OK() bool { return s.ok }

// Since is what changed after the snapshot.
func (s Snapshot) Since() Change {
	if !s.ok {
		return Change{}
	}
	c, cancel := ctx()
	defer cancel()
	var ch Change
	head := ""
	if out, err := git(c, s.Dir, "rev-parse", "--verify", "-q", "HEAD"); err == nil {
		head = strings.TrimSpace(out)
	}
	switch {
	case head == "" || head == s.Head:
		n := 0
		ch.Commits = &n
	case s.Head == "":
		if out, err := git(c, s.Dir, "rev-list", "--count", head); err == nil {
			ch.Commits = atoi(out)
		}
	default:
		if out, err := git(c, s.Dir, "rev-list", "--count", s.Head+".."+head); err == nil {
			ch.Commits = atoi(out)
		}
	}
	files := map[string]bool{}
	// Committed during the session.
	if s.Head != "" && head != "" && head != s.Head {
		out, err := git(c, s.Dir, "diff", "--name-only", "-z", s.Head, head)
		if err != nil {
			return ch
		}
		for _, p := range splitZ(out) {
			files[p] = true
		}
	}
	// Dirty now: new, or changed since the snapshot.
	now, err := dirty(c, s.Dir)
	if err != nil {
		return ch
	}
	var recheck []string
	for _, p := range now {
		if _, was := s.Dirty[p]; was {
			recheck = append(recheck, p)
		} else {
			files[p] = true
		}
	}
	if len(recheck) > 0 {
		hs, err := hashFiles(c, s.Dir, recheck)
		if err != nil {
			return ch
		}
		for _, p := range recheck {
			if hs[p] != s.Dirty[p] {
				files[p] = true
			}
		}
	}
	// Dirty before and clean now: committed or reverted, either way changed.
	nowSet := map[string]bool{}
	for _, p := range now {
		nowSet[p] = true
	}
	for p := range s.Dirty {
		if !nowSet[p] {
			files[p] = true
		}
	}
	n := len(files)
	ch.Files = &n
	return ch
}

// dirty lists tracked files that differ from HEAD and untracked files that
// are not ignored.
func dirty(c context.Context, dir string) ([]string, error) {
	out, err := git(c, dir, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	var paths []string
	parts := splitZ(out)
	for i := 0; i < len(parts); i++ {
		e := parts[i]
		if len(e) < 4 {
			continue
		}
		x := e[0]
		paths = append(paths, e[3:])
		if x == 'R' || x == 'C' {
			i++ // the rename source follows
		}
	}
	sort.Strings(paths)
	return paths, nil
}

// hashFiles fingerprints the working-tree content of paths without writing
// any object. A deleted file hashes to "".
func hashFiles(c context.Context, dir string, paths []string) (map[string]string, error) {
	out := make(map[string]string, len(paths))
	if len(paths) == 0 {
		return out, nil
	}
	cmd := exec.CommandContext(c, "git", append(append([]string{"-C", dir}, quiet...), "hash-object", "--no-filters", "--stdin-paths")...)
	var in, res bytes.Buffer
	var present []string
	for _, p := range paths {
		if fileExists(dir, p) {
			present = append(present, p)
			in.WriteString(p + "\n")
		} else {
			out[p] = ""
		}
	}
	if len(present) == 0 {
		return out, nil
	}
	cmd.Stdin, cmd.Stdout = &in, &res
	if err := cmd.Run(); err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(res.String()), "\n")
	if len(lines) != len(present) {
		return nil, exec.ErrNotFound
	}
	for i, p := range present {
		out[p] = lines[i]
	}
	return out, nil
}

func splitZ(s string) []string {
	var out []string
	for _, p := range strings.Split(s, "\x00") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func atoi(s string) *int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return nil
	}
	return &n
}

func fileExists(dir, p string) bool {
	st, err := os.Lstat(filepath.Join(dir, p))
	return err == nil && !st.IsDir()
}
