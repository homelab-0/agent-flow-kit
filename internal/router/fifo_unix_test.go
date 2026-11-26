//go:build unix

package router

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestCodexSkipsNamedPipes(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".codex/sessions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(dir, "rollout-2026-11-26T09.jsonl"), 0o600); err != nil {
		t.Skip("mkfifo:", err)
	}
	done := make(chan quota, 1)
	go func() { done <- probeCodexQuota(ProbeEnv{Home: home, Now: time.Now()}) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the probe blocked on a named pipe")
	}
}
