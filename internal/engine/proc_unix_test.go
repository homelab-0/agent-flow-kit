//go:build unix

package engine

import (
	"errors"
	"syscall"
)

// processAlive reports whether pid still exists. A process that has exited
// but has not been reaped yet counts as gone.
func processAlive(pid int) bool {
	if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
		return false
	}
	var ws syscall.WaitStatus
	// Only our own children can be reaped here; any other pid gives ECHILD.
	if wp, _ := syscall.Wait4(pid, &ws, syscall.WNOHANG, nil); wp == pid {
		return false
	}
	return !isZombie(pid)
}

func killPid(pid int) { _ = syscall.Kill(pid, syscall.SIGKILL) }
