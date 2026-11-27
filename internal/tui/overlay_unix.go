//go:build unix

package tui

import (
	"os"

	"golang.org/x/sys/unix"
)

// ttyCellSize is a cell's size in pixels from the terminal's window size
// (TIOCGWINSZ), for terminals that don't answer CSI 16 t: xterm only does
// with allowWindowOps. 0, 0 when the terminal doesn't fill it in.
func ttyCellSize() (w, h int) {
	f, err := os.Open("/dev/tty")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	ws, err := unix.IoctlGetWinsize(int(f.Fd()), unix.TIOCGWINSZ)
	if err != nil || ws.Col == 0 || ws.Row == 0 {
		return 0, 0
	}
	return int(ws.Xpixel) / int(ws.Col), int(ws.Ypixel) / int(ws.Row)
}
