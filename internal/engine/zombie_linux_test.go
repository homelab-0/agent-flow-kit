package engine

import (
	"os"
	"strconv"
	"strings"
)

// isZombie reads the process state from /proc: Z means exited, waiting to
// be reaped by whoever adopted it.
func isZombie(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return os.IsNotExist(err)
	}
	s := string(b)
	i := strings.LastIndexByte(s, ')')
	return i >= 0 && i+2 < len(s) && s[i+2] == 'Z'
}
