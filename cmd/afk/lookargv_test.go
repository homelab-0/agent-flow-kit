package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLookArgv0SkipsRelativePathEntries(t *testing.T) {
	proj, real := t.TempDir(), t.TempDir()
	for _, d := range []string{proj, real} {
		if err := os.WriteFile(filepath.Join(d, "tool"), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Chdir(proj)
	sep := string(os.PathListSeparator)
	got, err := lookArgv0("tool", []string{"PATH=." + sep + sep + real})
	if err != nil || got != filepath.Join(real, "tool") {
		t.Fatalf("got %q %v", got, err)
	}
	if _, err := lookArgv0("tool", []string{"PATH=."}); err == nil {
		t.Fatal("found the project's own file")
	}
}
