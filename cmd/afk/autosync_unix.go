//go:build unix

package main

import (
	"os"
	"os/exec"
	"syscall"

	"github.com/homelab-0/agent-flow-kit/internal/bench"
)

// refreshBenchmarks starts the daily catalog refresh in the background
// when it is due, so routing never waits on the network for it: this run
// routes with the catalog it has, the next one with the refreshed one.
func refreshBenchmarks(home string) {
	if !bench.Due(bench.Env{Home: home, Getenv: os.Getenv}) {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(exe, "bench", "sync", "--auto")
	// Its own session, no terminal and no output: it outlives afk and
	// never writes over the CLI's screen.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if cmd.Start() == nil {
		_ = cmd.Process.Release()
	}
}
