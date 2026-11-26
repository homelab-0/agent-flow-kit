//go:build unix

package launch

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func envMap(env []string) map[string]string {
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	return m
}

func TestBuildEnvOrder(t *testing.T) {
	base := []string{"PATH=/bin", "GW_KEY=sekrit", "ANTHROPIC_API_KEY=plan", "CLAUDE_CODE_OAUTH_TOKEN=plan2", "KEEP=1"}
	env, err := BuildEnv(base,
		map[string]string{"ANTHROPIC_BASE_URL": "http://gw", "CLAUDE_CONFIG_DIR": "/tmp/x"},
		map[string]string{"ANTHROPIC_AUTH_TOKEN": "GW_KEY"},
		[]string{"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "GW_KEY"})
	if err != nil {
		t.Fatal(err)
	}
	m := envMap(env)
	if m["ANTHROPIC_AUTH_TOKEN"] != "sekrit" {
		t.Error("the env_from source is read before env_unset, so unsetting it cannot empty the copy")
	}
	if _, ok := m["GW_KEY"]; ok {
		t.Error("env_unset removes the source itself")
	}
	for _, k := range []string{"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"} {
		if _, ok := m[k]; ok {
			t.Errorf("%s is unset", k)
		}
	}
	if m["ANTHROPIC_BASE_URL"] != "http://gw" || m["KEEP"] != "1" || m["PATH"] != "/bin" {
		t.Errorf("env %v", m)
	}
}

func TestBuildEnvRefusals(t *testing.T) {
	base := []string{"EMPTY=", "OK_KEY=v", "ANTHROPIC_API_KEY=plan", "OPENAI_API_KEY=x", "CODEX_X=x", "XAI_K=x", "GROK_K=x", "GEMINI_K=x", "GOOGLE_K=x", "OPENCODE_K=x", "CLAUDE_CODE_OAUTH_TOKEN=x"}
	for _, src := range []string{"EMPTY", "MISSING", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_X", "XAI_K", "GROK_K", "GEMINI_K", "GOOGLE_K", "OPENCODE_K", "CLAUDE_CODE_OAUTH_TOKEN", "bad name"} {
		_, err := BuildEnv(base, nil, map[string]string{"ANTHROPIC_AUTH_TOKEN": src}, nil)
		var ee *EnvError
		if !errors.As(err, &ee) {
			t.Errorf("source %q is refused, got %v", src, err)
			continue
		}
		for _, kv := range base {
			_, v, _ := strings.Cut(kv, "=")
			if v != "" && strings.Contains(ee.Error(), "="+v) {
				t.Errorf("the refusal names no value: %s", ee)
			}
		}
	}
	if _, err := BuildEnv(base, nil, map[string]string{"ANTHROPIC_AUTH_TOKEN": "OK_KEY"}, nil); err != nil {
		t.Errorf("a plain gateway key variable is fine: %v", err)
	}
}

func TestRunExitCwdEnv(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "out")
	script := filepath.Join(dir, "cli")
	os.WriteFile(script, []byte("#!/bin/sh\npwd > \"$OUT\"\nprintf '%s|%s\\n' \"$A\" \"$1\" >> \"$OUT\"\nexit 3\n"), 0o755)
	res, err := Run(Spec{Argv: []string{script, "arg one"}, Env: []string{"OUT=" + out, "A=a", "PATH=/usr/bin:/bin"}, Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if res.ExitCode != 3 || res.Signal != "" || res.Duration() < 0 {
		t.Errorf("result %+v", res)
	}
	b, _ := os.ReadFile(out)
	real, _ := filepath.EvalSymlinks(dir)
	if got := string(b); got != real+"\na|arg one\n" && got != dir+"\na|arg one\n" {
		t.Errorf("child saw %q", got)
	}
}

func TestRunSignal(t *testing.T) {
	res, err := Run(Spec{Argv: []string{"/bin/sh", "-c", "kill -TERM $$"}, Env: []string{"PATH=/usr/bin:/bin"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.ExitCode != 128+15 || res.Signal != "SIGTERM" {
		t.Errorf("result %+v", res)
	}
}

func TestRunMissing(t *testing.T) {
	if _, err := Run(Spec{Argv: []string{"/nonexistent/cli"}}); err == nil {
		t.Error("a missing CLI is an error")
	}
}

// --- with a real terminal ------------------------------------------------
//
// These run the test binary itself as a helper under script(1), which gives
// it a pseudo-terminal as its controlling terminal.

func TestMain(m *testing.M) {
	if mode := os.Getenv("AFK_LAUNCH_HELPER"); mode != "" {
		os.Exit(helper(mode))
	}
	os.Exit(m.Run())
}

func helper(mode string) int {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fmt.Println("NO_TTY", err)
		return 2
	}
	argv := []string{"/bin/sh", "-c", `awk '{ if ($5 == $8) print "CHILD_FOREGROUND"; else print "CHILD_BACKGROUND" }' /proc/self/stat; exit 7`}
	if mode == "missing" {
		argv = []string{"/nonexistent/afk-cli"}
	}
	res, err := Run(Spec{Argv: argv, Env: []string{"PATH=/usr/bin:/bin"}, TTY: tty})
	fmt.Printf("RESULT exit=%d err=%v\n", res.ExitCode, err != nil)
	pg, gerr := unix.IoctlGetInt(int(tty.Fd()), unix.TIOCGPGRP)
	if gerr == nil && pg == syscall.Getpgrp() {
		fmt.Println("TERMINAL_BACK")
	} else {
		fmt.Println("TERMINAL_LOST", pg, syscall.Getpgrp(), gerr)
	}
	return 0
}

func underPTY(t *testing.T, mode string) string {
	t.Helper()
	// The helper reads /proc/self/stat, and script -e -c is util-linux's.
	if runtime.GOOS != "linux" {
		t.Skip("needs Linux script(1) and /proc")
	}
	if _, err := exec.LookPath("script"); err != nil {
		t.Skip("script(1) is not installed")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("script", "-qec", exe+" -test.run=^$", "/dev/null")
	cmd.Env = append(os.Environ(), "AFK_LAUNCH_HELPER="+mode)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper under script: %v\n%s", err, out)
	}
	return string(out)
}

func TestPTYForegroundRun(t *testing.T) {
	out := underPTY(t, "run")
	for _, want := range []string{"CHILD_FOREGROUND", "RESULT exit=7 err=false", "TERMINAL_BACK"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in:\n%s", want, out)
		}
	}
}

func TestPTYExecFailureGivesTerminalBack(t *testing.T) {
	out := underPTY(t, "missing")
	for _, want := range []string{"RESULT exit=0 err=true", "TERMINAL_BACK"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in:\n%s", want, out)
		}
	}
}

func TestRunForwardsTerm(t *testing.T) {
	go func() {
		time.Sleep(300 * time.Millisecond)
		_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	}()
	res, err := Run(Spec{Argv: []string{"/bin/sh", "-c", "exec sleep 5"}, Env: []string{"PATH=/usr/bin:/bin"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Signal != "SIGTERM" && res.ExitCode != 128+15 {
		t.Errorf("SIGTERM reaches the child and afk keeps waiting: %+v", res)
	}
}

func TestRunLeavesTTINStoppedChild(t *testing.T) {
	// Not in the foreground: a child stopped by SIGTTIN is not resumed (it
	// would only stop again). It stays stopped until something ends it; here
	// a helper it started kills it after a moment.
	if !stopsReachUs() {
		t.Skip("SIGTTIN is discarded here (an orphaned process group, as under some CI runners)")
	}
	start := time.Now()
	res, err := Run(Spec{Argv: []string{"/bin/sh", "-c", "(sleep 0.6; kill -KILL $$) & kill -TTIN $$; exit 0"}, Env: []string{"PATH=/usr/bin:/bin"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Signal != "SIGKILL" || time.Since(start) < 500*time.Millisecond {
		t.Errorf("the stopped child was resumed instead of left stopped: %+v after %v", res, time.Since(start))
	}
}

// stopsReachUs reports whether SIGTTIN stops a child in our process
// group. The kernel discards it when the group is orphaned, as it is under
// some CI runners, so the test above can't tell anything there.
func stopsReachUs() bool {
	cmd := exec.Command("/bin/sh", "-c", "kill -TTIN $$; exit 0")
	if cmd.Start() != nil {
		return false
	}
	pid := cmd.Process.Pid
	var ws syscall.WaitStatus
	for {
		_, err := syscall.Wait4(pid, &ws, syscall.WUNTRACED, nil)
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil {
			return false
		}
		break
	}
	if ws.Stopped() {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		_, _ = syscall.Wait4(pid, &ws, 0, nil)
		return true
	}
	return false
}
