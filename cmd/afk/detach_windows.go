//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// detach starts cmd without this console, so it outlives the terminal
// that started it.
func detach(cmd *exec.Cmd) {
	const detachedProcess, newProcessGroup = 0x00000008, 0x00000200
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: detachedProcess | newProcessGroup, HideWindow: true}
}
