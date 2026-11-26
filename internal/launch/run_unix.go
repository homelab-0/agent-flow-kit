//go:build unix

package launch

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Spec is what to start.
type Spec struct {
	Argv []string
	Env  []string
	Dir  string
	// TTY is the controlling terminal. When set, the child gets its own
	// process group in the foreground of that terminal, and afk takes the
	// terminal back when the child exits or stops. When nil the child just
	// inherits stdio (tests, no terminal).
	TTY *os.File
}

// Result is how the child ended.
type Result struct {
	ExitCode int    // the exit status, or 128+signal
	Signal   string // the signal that ended it, if any
	Started  time.Time
	Ended    time.Time
}

// Duration is how long the child ran.
func (r Result) Duration() time.Duration { return r.Ended.Sub(r.Started) }

// Run starts the child and waits for it. While it runs afk ignores SIGINT,
// SIGQUIT and SIGTSTP: they are meant for the child. The signals are caught
// rather than set to SIG_IGN, so the child does not inherit an ignored
// disposition across exec. SIGTERM and SIGHUP are passed on to the child's
// process group, and afk keeps waiting so it can put the terminal back.
// Whatever happens, a child that was given the terminal hands it back.
func Run(s Spec) (res Result, err error) {
	if len(s.Argv) == 0 {
		return Result{}, errors.New("nothing to start")
	}
	sink := make(chan os.Signal, 8)
	signal.Notify(sink, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGTSTP)
	pass := make(chan os.Signal, 4)
	var target atomic.Int64 // the pid (or -pgid) to pass signals to; 0 before start
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-sink:
			case sig := <-pass:
				if t := target.Load(); t != 0 {
					_ = syscall.Kill(int(t), sig.(syscall.Signal))
				}
			case <-done:
				return
			}
		}
	}()
	defer func() {
		signal.Stop(sink)
		signal.Stop(pass)
		close(done)
	}()

	attr := &os.ProcAttr{
		Dir:   s.Dir,
		Env:   s.Env,
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
		Sys:   &syscall.SysProcAttr{},
	}
	fg := s.TTY != nil && isForeground(s.TTY)
	if fg {
		attr.Sys.Foreground = true
		attr.Sys.Ctty = int(s.TTY.Fd())
		// On every way out, including a failed exec (the forked child had
		// already taken the foreground) and a panic.
		defer takeTerminal(s.TTY)
	}
	res = Result{Started: time.Now()}
	proc, err := os.StartProcess(s.Argv[0], s.Argv, attr)
	if err != nil {
		return res, fmt.Errorf("cannot start %s: %w", s.Argv[0], err)
	}
	defer func() { _ = proc.Release() }()
	pid := proc.Pid
	if fg {
		target.Store(int64(-pid))
	} else {
		target.Store(int64(pid))
	}
	signal.Notify(pass, syscall.SIGTERM, syscall.SIGHUP)
	for {
		var ws syscall.WaitStatus
		_, err := syscall.Wait4(pid, &ws, syscall.WUNTRACED, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil {
			return res, fmt.Errorf("waiting for %s: %w", s.Argv[0], err)
		}
		switch {
		case ws.Stopped():
			if !fg {
				// Without the terminal, a child stopped for reading or
				// writing it would only stop again: leave it stopped (it
				// can still be killed), and resume only a plain suspend.
				if sig := ws.StopSignal(); sig == syscall.SIGTTIN || sig == syscall.SIGTTOU {
					continue
				}
				_ = syscall.Kill(pid, syscall.SIGCONT)
				continue
			}
			// The child stopped itself (ctrl+z, or a background read). Do
			// what a shell would: take the terminal back and stop afk too,
			// so the user's shell gets control; on fg, hand the terminal
			// back to the child and let it continue.
			takeTerminal(s.TTY)
			suspendSelf(sink)
			giveTerminal(s.TTY, pid)
			_ = syscall.Kill(-pid, syscall.SIGCONT)
		case ws.Exited():
			res.Ended = time.Now()
			res.ExitCode = ws.ExitStatus()
			return res, nil
		case ws.Signaled():
			res.Ended = time.Now()
			res.ExitCode = 128 + int(ws.Signal())
			res.Signal = unix.SignalName(ws.Signal())
			return res, nil
		}
	}
}

// suspendSelf stops afk with SIGTSTP at its default action, so the shell
// that started afk gets the terminal. In an orphaned process group (no job
// control above afk) the kernel discards the stop and afk carries on, which
// resumes the child instead of leaving both stopped for good.
func suspendSelf(sink chan os.Signal) {
	signal.Reset(syscall.SIGTSTP)
	_ = syscall.Kill(syscall.Getpid(), syscall.SIGTSTP)
	signal.Notify(sink, syscall.SIGTSTP)
}

// isForeground reports whether afk's process group owns the terminal, so it
// may hand the terminal to a child.
func isForeground(tty *os.File) bool {
	pg, err := unix.IoctlGetInt(int(tty.Fd()), unix.TIOCGPGRP)
	return err == nil && pg == syscall.Getpgrp()
}

// takeTerminal makes afk's process group the terminal's foreground again.
// afk is in the background at that point, so SIGTTOU is ignored for the
// call; nothing is started in that window, so no child inherits it.
func takeTerminal(tty *os.File) {
	setForeground(tty, syscall.Getpgrp())
}

func giveTerminal(tty *os.File, pgid int) { setForeground(tty, pgid) }

func setForeground(tty *os.File, pgid int) {
	signal.Ignore(syscall.SIGTTOU)
	defer signal.Reset(syscall.SIGTTOU)
	for i := 0; i < 5; i++ {
		err := unix.IoctlSetPointerInt(int(tty.Fd()), unix.TIOCSPGRP, pgid)
		if !errors.Is(err, syscall.EINTR) {
			return
		}
	}
}
