package harness

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// A relative PATH entry would find a "claude" shipped by the project afk
// was started in.
func TestLocateSkipsRelativePathEntries(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell stubs")
	}
	proj, real := t.TempDir(), t.TempDir()
	for _, d := range []string{proj, real} {
		if err := os.WriteFile(filepath.Join(d, "claude"), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Chdir(proj)
	a, ok := Lookup("claude")
	if !ok {
		t.Fatal("no claude adapter")
	}
	home := t.TempDir()
	sep := string(os.PathListSeparator)
	for _, path := range []string{"." + sep + real, sep + real, "bin/.." + sep + real} {
		got := Locate(Env{Home: home, Path: path, OS: runtime.GOOS}, a)
		if got != filepath.Join(real, "claude") {
			t.Errorf("PATH=%q found %q", path, got)
		}
	}
	if got := Locate(Env{Home: home, Path: ".", OS: runtime.GOOS}, a); got != "" && filepath.Dir(got) == proj {
		t.Errorf("found the project's own file: %q", got)
	}
}
