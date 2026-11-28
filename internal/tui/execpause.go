package tui

import (
	"bufio"
	"fmt"
	"io"
	"os/exec"

	tea "charm.land/bubbletea/v2"
)

// pausedCmd runs a command AFK handed the terminal to (an update, a
// sign-in, a sync), then waits for ↵ before AFK draws again, so what the
// command said can be read. Without the wait the full-screen tab would
// cover it at once.
type pausedCmd struct {
	c      *exec.Cmd
	in     io.Reader
	out    io.Writer
	noWait bool // an editor: its own screen was the point
}

func (p *pausedCmd) SetStdin(r io.Reader)  { p.in = r; p.c.Stdin = r }
func (p *pausedCmd) SetStdout(w io.Writer) { p.out = w; p.c.Stdout = w }
func (p *pausedCmd) SetStderr(w io.Writer) { p.c.Stderr = w }

func (p *pausedCmd) Run() error {
	err := p.c.Run()
	if p.noWait || p.in == nil || p.out == nil {
		return err
	}
	fmt.Fprint(p.out, "\n  ↵ back to AFK ")
	_, _ = bufio.NewReader(p.in).ReadString('\n')
	return err
}

// execPaused hands the terminal to argv and calls back with its error once
// ↵ has been pressed after it.
func execPaused(argv []string, noWait bool, fn func(error) tea.Msg) tea.Cmd {
	c := exec.Command(argv[0], argv[1:]...)
	return tea.Exec(&pausedCmd{c: c, noWait: noWait}, fn)
}
