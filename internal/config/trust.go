package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// GitRoot is the git repository a directory is in ("" when none): the
// nearest directory upwards with a .git directory or file.
func GitRoot(dir string) string {
	d := realDir(dir)
	for {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
		d = parent
	}
}

func realDir(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

// within reports whether p is dir or inside it.
func within(p, dir string) bool {
	if p == dir {
		return true
	}
	rel, err := filepath.Rel(dir, p)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// ErrNotTrusted is yolo asked for outside a trusted git repository.
type ErrNotTrusted struct{ Msg string }

func (e *ErrNotTrusted) Error() string { return e.Msg }

// CheckYolo says whether yolo may run in dir: dir must be inside a git
// repository that is, or is under, a directory in trust.repos, and never
// your home directory itself. The refusal names the afk trust add command
// that would allow it.
func CheckYolo(s Settings, home, dir string) error {
	root := GitRoot(dir)
	if root == "" {
		return &ErrNotTrusted{fmt.Sprintf("yolo runs only inside a git repository, and %s isn't in one", dir)}
	}
	h := realDir(home)
	if root == h || within(h, root) {
		return &ErrNotTrusted{fmt.Sprintf("yolo never runs with your home directory as the repository (%s); use a repository below it", root)}
	}
	for _, t := range s.TrustedDirs {
		if within(root, realDir(expandHome(t, home))) {
			return nil
		}
	}
	return &ErrNotTrusted{fmt.Sprintf("yolo runs only in a trusted repository; to allow it here run: afk trust add %s", root)}
}

func expandHome(p, home string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

// TrustChange is the result of afk trust add or remove.
type TrustChange struct {
	Dir     string   `json:"dir"`
	Repos   []string `json:"repos"`   // trust.repos after the change
	Covers  []string `json:"covers"`  // git repositories the directory now covers
	Diff    string   `json:"diff"`    // config.toml before and after
	Changed bool     `json:"changed"` // false when nothing needed changing
	// StillTrustedBy, after a remove, is the trust.repos entries that
	// still cover the directory, so yolo stays allowed there.
	StillTrustedBy []string `json:"still_trusted_by,omitempty"`
}

// CheckTrustable says whether dir may be trusted: an existing directory,
// not your home directory or anything above it (/home, /), that is a git
// repository, inside one, or holds git repositories below it.
func CheckTrustable(home, dir string) (string, []string, error) {
	d := realDir(expandHome(dir, home))
	fi, err := os.Stat(d)
	if err != nil || !fi.IsDir() {
		return "", nil, fmt.Errorf("%s is not a directory", dir)
	}
	// Inside a repository, the repository itself is what is trusted:
	// yolo checks the repository root, so a subdirectory entry would
	// never match.
	root := GitRoot(d)
	if root != "" {
		d = root
	}
	h := realDir(home)
	if d == h || within(h, d) {
		return "", nil, fmt.Errorf("%s is your home directory or above it; trust a repository or a folder of repositories below it instead", d)
	}
	covers := []string{root}
	if root == "" {
		covers = reposUnder(d)
	}
	if len(covers) == 0 {
		return "", nil, fmt.Errorf("%s is not a git repository and has none below it", d)
	}
	return d, covers, nil
}

// reposUnder lists git repositories at most three levels below dir.
func reposUnder(dir string) []string {
	var out []string
	var walk func(d string, depth int)
	walk = func(d string, depth int) {
		if depth > 3 {
			return
		}
		ents, err := os.ReadDir(d)
		if err != nil {
			return
		}
		for _, e := range ents {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			p := filepath.Join(d, e.Name())
			if _, err := os.Stat(filepath.Join(p, ".git")); err == nil {
				out = append(out, p)
				continue
			}
			walk(p, depth+1)
		}
	}
	walk(dir, 1)
	sort.Strings(out)
	return out
}

// TrustAdd adds a directory to trust.repos in config.toml.
func TrustAdd(paths Paths, home, dir string, dryRun bool) (*TrustChange, error) {
	d, covers, err := CheckTrustable(home, dir)
	if err != nil {
		return nil, err
	}
	return changeTrust(paths, func(cur []string) ([]string, bool) {
		for _, t := range cur {
			if realDir(expandHome(t, home)) == d {
				return cur, false
			}
		}
		return append(cur, d), true
	}, d, covers, dryRun)
}

// TrustRemove takes a directory out of trust.repos.
func TrustRemove(paths Paths, home, dir string, dryRun bool) (*TrustChange, error) {
	d := realDir(expandHome(dir, home))
	drop := func(cur []string, d string) ([]string, bool) {
		var out []string
		found := false
		for _, t := range cur {
			if t == dir || realDir(expandHome(t, home)) == d {
				found = true
				continue
			}
			out = append(out, t)
		}
		return out, found
	}
	ch, err := changeTrust(paths, func(cur []string) ([]string, bool) {
		if out, found := drop(cur, d); found {
			return out, true
		}
		// afk trust add saves the repository root for a directory inside
		// a repository, so the same argument removes it.
		if root := GitRoot(d); root != "" && root != d {
			if out, found := drop(cur, root); found {
				d = root
				return out, true
			}
		}
		return cur, false
	}, d, nil, dryRun)
	if err == nil && ch.Changed {
		ch.Dir = d
	}
	if err == nil && !ch.Changed {
		return ch, fmt.Errorf("%s is not in trust.repos", dir)
	}
	if err == nil {
		for _, t := range ch.Repos {
			if within(d, realDir(expandHome(t, home))) {
				ch.StillTrustedBy = append(ch.StillTrustedBy, t)
			}
		}
	}
	return ch, err
}

func changeTrust(paths Paths, edit func([]string) ([]string, bool), dir string, covers []string, dryRun bool) (*TrustChange, error) {
	ch := &TrustChange{Dir: dir, Covers: covers}
	if covers == nil {
		ch.Covers = []string{}
	}
	do := func(write bool) error {
		f, err := Load(paths.Config)
		if err != nil {
			return err
		}
		if !f.Exists {
			if _, err := os.Stat(paths.Legacy); err == nil {
				return errLegacyFirst(paths)
			}
		}
		next, changed := edit(append([]string(nil), f.Trust.Repos...))
		ch.Repos, ch.Changed = next, changed
		if ch.Repos == nil {
			ch.Repos = []string{}
		}
		if !changed {
			return nil
		}
		doc := []byte(Template)
		old := ""
		if f.Exists {
			doc, old = f.Raw, string(f.Raw)
		}
		q := make([]string, len(next))
		for i, t := range next {
			q[i] = quote(t)
		}
		after, err := SetValue(doc, "trust.repos", "["+strings.Join(q, ", ")+"]")
		if err != nil {
			return err
		}
		if _, err := Parse(paths.Config, after); err != nil {
			return err
		}
		ch.Diff = unified(paths.Config, old, string(after))
		if !write {
			return nil
		}
		return writeFile(paths.Config, after)
	}
	if dryRun {
		return ch, do(false)
	}
	return ch, withLock(paths.Config, func() error { return do(true) })
}
