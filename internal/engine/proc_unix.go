//go:build unix

package engine

import (
	"os/exec"
	"syscall"
)

// ownGroup runs an engine call in its own process group, so a cancel kills
// the bash engine and everything it started, not just the first process.
func ownGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}
