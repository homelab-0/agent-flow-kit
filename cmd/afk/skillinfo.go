package main

import (
	"bufio"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// skillInfo reads what the Skills tab shows about a skill's own folder:
// the description from its SKILL.md front matter, how many files it
// has and when one last changed. A missing folder gives zero values.
func skillInfo(dir string) (desc string, files int, mod time.Time) {
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		files++
		if fi, err := d.Info(); err == nil && fi.ModTime().After(mod) {
			mod = fi.ModTime()
		}
		return nil
	})
	f, err := os.Open(filepath.Join(dir, "SKILL.md"))
	if err != nil {
		return "", files, mod
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	inFront := false
	for n := 0; sc.Scan() && n < 40; n++ {
		l := strings.TrimSpace(sc.Text())
		if l == "---" {
			if inFront {
				break
			}
			inFront = n == 0
			continue
		}
		if !inFront {
			break
		}
		if v, ok := strings.CutPrefix(l, "description:"); ok {
			desc = strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return desc, files, mod
}
