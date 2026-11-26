package statefile

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestNewStateIsPrivate(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix modes")
	}
	dest := filepath.Join(t.TempDir(), "state", "signals.json")
	if err := WriteJSON(dest, []byte("{}\n")); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(dest); fi.Mode().Perm() != 0o600 {
		t.Errorf("file mode %v", fi.Mode().Perm())
	}
	if fi, _ := os.Stat(filepath.Dir(dest)); fi.Mode().Perm() != 0o700 {
		t.Errorf("directory mode %v", fi.Mode().Perm())
	}
	// A file you opened up yourself keeps its mode.
	if err := os.Chmod(dest, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := WriteJSON(dest, []byte("{\"a\":1}\n")); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(dest); fi.Mode().Perm() != 0o644 {
		t.Errorf("kept mode %v", fi.Mode().Perm())
	}
}
