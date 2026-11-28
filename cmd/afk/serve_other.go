//go:build !unix

package main

import "os"

// processAlive reports whether pid is a running process. Without signals
// to probe with, a process that can be opened counts as running.
func processAlive(pid int) bool {
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	_ = p.Release()
	return true
}

// stopProcess ends pid.
func stopProcess(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Kill()
}
