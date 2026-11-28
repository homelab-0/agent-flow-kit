//go:build !unix && !windows

package main

import "os/exec"

// detach does nothing where a process can't be given a session of its own.
func detach(*exec.Cmd) {}
