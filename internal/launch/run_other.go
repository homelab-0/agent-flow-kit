//go:build !unix

package launch

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"time"
)

// Spec is what to start.
type Spec struct {
	Argv []string
	Env  []string
	Dir  string
	// TTY is the controlling terminal. Without unix job control the child
	// simply shares afk's console, so it is only used to know a terminal is
	// there.
	TTY *os.File
}

// Result is how the child ended.
type Result struct {
	ExitCode int    // the exit status
	Signal   string // always empty here: there are no unix signals
	Started  time.Time
	Ended    time.Time
}

// Duration is how long the child ran.
func (r Result) Duration() time.Duration { return r.Ended.Sub(r.Started) }

// Run starts the child on afk's console and waits for it. Ctrl+C reaches
// every process on the console, so afk catches it and keeps waiting: the
// child decides what an interrupt means.
func Run(s Spec) (res Result, err error) {
	if len(s.Argv) == 0 {
		return Result{}, errors.New("nothing to start")
	}
	sink := make(chan os.Signal, 8)
	signal.Notify(sink, os.Interrupt)
	defer signal.Stop(sink)

	cmd := exec.Command(s.Argv[0], s.Argv[1:]...)
	cmd.Dir = s.Dir
	cmd.Env = s.Env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	res = Result{Started: time.Now()}
	if err := cmd.Start(); err != nil {
		return res, fmt.Errorf("cannot start %s: %w", s.Argv[0], err)
	}
	werr := cmd.Wait()
	res.Ended = time.Now()
	var ee *exec.ExitError
	if werr != nil && !errors.As(werr, &ee) {
		return res, fmt.Errorf("waiting for %s: %w", s.Argv[0], werr)
	}
	res.ExitCode = cmd.ProcessState.ExitCode()
	return res, nil
}
