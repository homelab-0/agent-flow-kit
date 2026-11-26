package harness

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Schema is the version of the JSON that Report marshals to.
const Schema = "afk-harnesses/3"

// Info is what discovery found for one CLI.
type Info struct {
	Name          string    `json:"name"`
	Display       string    `json:"display"`
	Vendor        string    `json:"vendor"`
	Installed     bool      `json:"installed"`
	Healthy       bool      `json:"healthy"`
	Problem       string    `json:"problem,omitempty"`
	Binary        string    `json:"binary,omitempty"`
	ResolvedPath  string    `json:"resolved_path,omitempty"`
	Version       string    `json:"version,omitempty"`
	InstallMethod string    `json:"install_method,omitempty"`
	Package       string    `json:"package,omitempty"`
	UpdateCommand []string  `json:"update_command,omitempty"`
	Auth          AuthState `json:"auth"`
	AuthNote      string    `json:"auth_note,omitempty"`
	Login         string    `json:"login,omitempty"`
	Efforts       []string  `json:"efforts"`
	EffortFlag    string    `json:"effort_flag,omitempty"`
}

// Report is the result of discovering every known CLI.
type Report struct {
	Schema    string `json:"schema"`
	OS        string `json:"os"`
	CheckedAt string `json:"checked_at"`
	Harnesses []Info `json:"harnesses"`
}

// Installed returns only the CLIs found on this machine.
func (r Report) Installed() []Info {
	var out []Info
	for _, h := range r.Harnesses {
		if h.Installed {
			out = append(out, h)
		}
	}
	return out
}

// Options tune discovery.
type Options struct {
	// VersionTimeout bounds each "<cli> --version" call (default 5s).
	VersionTimeout time.Duration
	// SkipVersion leaves versions out and runs nothing.
	SkipVersion bool
	// Now is the clock (tests).
	Now func() time.Time
}

// Discover inspects every known CLI. Version checks run in parallel, so the
// whole call takes about as long as the slowest CLI.
func Discover(ctx context.Context, e Env, o Options) Report {
	ads := All()
	out := make([]Info, len(ads))
	var wg sync.WaitGroup
	for i, a := range ads {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out[i] = Inspect(ctx, e, a, o)
		}()
	}
	wg.Wait()
	now := time.Now
	if o.Now != nil {
		now = o.Now
	}
	return Report{Schema: Schema, OS: e.OS, CheckedAt: now().UTC().Format(time.RFC3339), Harnesses: out}
}

// Inspect looks at one CLI.
func Inspect(ctx context.Context, e Env, a Adapter, o Options) Info {
	efforts := a.Efforts
	if efforts == nil {
		efforts = []string{}
	}
	in := Info{
		Name: a.Name, Display: a.Display, Vendor: a.Vendor,
		Auth: AuthNotInstalled, Efforts: efforts, EffortFlag: a.EffortFlag,
	}
	bin := Locate(e, a)
	if bin == "" {
		return in
	}
	in.Installed, in.Healthy, in.Binary, in.Login = true, true, bin, a.Login
	in.ResolvedPath = resolve(bin)
	in.InstallMethod, in.Package, in.UpdateCommand = classify(a, bin, in.ResolvedPath)

	if a.auth != nil {
		in.Auth, in.AuthNote = a.auth(e)
	} else {
		in.Auth = AuthUnknown
	}

	if !o.SkipVersion {
		t := o.VersionTimeout
		if t <= 0 {
			t = 5 * time.Second
		}
		v, problem := version(ctx, bin, t)
		in.Version = v
		if problem != "" {
			in.Healthy, in.Problem = false, problem
		}
	}
	return in
}

// extraDirs are where installers put CLIs that are often missing from PATH
// in non-login shells.
var extraDirs = []string{
	".local/bin", ".grok/bin", ".opencode/bin", ".bun/bin", ".cargo/bin",
	".npm-global/bin", ".local/share/mise/shims",
}

var systemDirs = []string{"/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin"}

// Locate finds the CLI's executable: on PATH first, then in the usual
// install directories. It returns "" when the CLI is not installed.
func Locate(e Env, a Adapter) string {
	var dirs []string
	if e.BinDir != "" {
		dirs = []string{e.BinDir}
	} else {
		dirs = filepath.SplitList(e.Path)
		for _, d := range extraDirs {
			dirs = append(dirs, filepath.Join(e.Home, d))
		}
		dirs = append(dirs, systemDirs...)
	}
	for _, name := range a.Bins {
		for _, d := range dirs {
			if d == "" {
				continue
			}
			for _, cand := range exeNames(e.OS, name) {
				p := filepath.Join(d, cand)
				if isExecutable(e.OS, p) {
					// An absolute path keeps a relative override such as
					// AFK_HARNESS_BIN_DIR=. pointing at this file when the
					// version check runs it, instead of a new PATH lookup.
					if abs, err := filepath.Abs(p); err == nil {
						return abs
					}
					return p
				}
			}
		}
	}
	return ""
}

func exeNames(goos, name string) []string {
	if goos == "windows" {
		return []string{name + ".exe", name + ".cmd", name + ".bat", name}
	}
	return []string{name}
}

func isExecutable(goos, p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	if goos == "windows" {
		return true
	}
	return fi.Mode().Perm()&0o111 != 0
}

func resolve(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

var semverRE = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?`)

// version runs "<bin> --version" with a time limit and pulls out the first
// version number. A CLI that fails or hangs is reported, not fatal.
func version(ctx context.Context, bin string, limit time.Duration) (string, string) {
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "--version")
	out := &capWriter{max: maxVersionOutput}
	cmd.Stdout, cmd.Stderr = out, out
	cmd.Stdin = nil
	// Node CLIs can leave children holding the pipe; don't wait on them.
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	text := out.String()
	v := semverRE.FindString(text)
	switch {
	case ctx.Err() == context.DeadlineExceeded:
		return v, "--version did not answer within " + limit.String()
	case err != nil:
		return v, "--version failed: " + firstLine(text, err.Error())
	}
	return v, ""
}

const maxVersionOutput = 4096

// capWriter keeps the first max bytes written to it and drops the rest,
// while still reporting every write as successful so the child keeps
// draining its output instead of blocking. A CLI that floods --version
// can't grow memory past max. It is safe for stdout and stderr to share.
type capWriter struct {
	mu  sync.Mutex
	max int
	buf bytes.Buffer
}

func (w *capWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if room := w.max - w.buf.Len(); room > 0 {
		if len(p) < room {
			room = len(p)
		}
		w.buf.Write(p[:room])
	}
	return len(p), nil
}

func (w *capWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.String()
}

func firstLine(text, fallback string) string {
	for _, l := range strings.Split(text, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			if len(l) > 90 {
				l = l[:90]
			}
			return l
		}
	}
	return fallback
}

// classify works out how the CLI was installed, from where its executable
// lives, and the command that updates it. The command is a list of words,
// never a shell string.
func classify(a Adapter, bin, resolved string) (method, pkg string, update []string) {
	paths := []string{filepath.ToSlash(bin), filepath.ToSlash(resolved)}
	has := func(sub string) bool {
		for _, p := range paths {
			if strings.Contains(p, sub) {
				return true
			}
		}
		return false
	}
	npmPkg := a.NPMPackage
	if npmPkg == "" {
		npmPkg = a.Bins[0]
	}
	r := filepath.ToSlash(resolved)
	switch {
	case has("/mise/installs/"):
		tool := after(r, "/mise/installs/")
		if tool == "" {
			tool = after(filepath.ToSlash(bin), "/mise/installs/")
		}
		return "mise", tool, []string{"mise", "upgrade", tool}
	case has("/mise/shims/") || has("/mise/command-wrappers/") || strings.HasSuffix(r, "/mise"):
		// A mise shim does not say which tool backs it, and a bare
		// "mise upgrade" would upgrade every tool, so no command is given.
		return "mise", "", nil
	case has("/.bun/"):
		p := nodePkg(r, npmPkg)
		return "bun", p, []string{"bun", "add", "-g", p + "@latest"}
	case has("/pnpm/"):
		p := nodePkg(r, npmPkg)
		return "pnpm", p, []string{"pnpm", "add", "-g", p + "@latest"}
	case has("/node_modules/"):
		p := nodePkg(r, npmPkg)
		return "npm", p, []string{"npm", "install", "-g", p + "@latest"}
	// Homebrew is checked after the Node package managers: npm, bun and
	// pnpm can install under the /opt/homebrew prefix too, and the
	// package layout says who manages the CLI better than the prefix does.
	case has("/Cellar/") || has("/Caskroom/") || has("/opt/homebrew/") || has("/home/linuxbrew/.linuxbrew/"):
		p := after(r, "/Cellar/")
		if p == "" {
			p = after(r, "/Caskroom/")
		}
		if p == "" {
			p = a.Bins[0]
		}
		return "homebrew", p, []string{"brew", "upgrade", p}
	case has("/uv/tools/"):
		p := after(r, "/uv/tools/")
		return "uv", p, []string{"uv", "tool", "upgrade", p}
	case has("/pipx/venvs/"):
		p := after(r, "/pipx/venvs/")
		return "pipx", p, []string{"pipx", "upgrade", p}
	case has("/.cargo/bin/"):
		return "cargo", a.Bins[0], []string{"cargo", "install", a.Bins[0]}
	}
	if a.SelfUpdate != "" {
		return "self-managed", "", []string{bin, a.SelfUpdate}
	}
	return "self-managed", "", nil
}

// after returns the path segment right after marker, or "".
func after(p, marker string) string {
	i := strings.Index(p, marker)
	if i < 0 {
		return ""
	}
	rest := p[i+len(marker):]
	if j := strings.IndexByte(rest, '/'); j >= 0 {
		rest = rest[:j]
	}
	return rest
}

// nodePkg reads the package name out of a .../node_modules/<pkg>/... path.
// A .bin link names no package, so the adapter's own name is used.
func nodePkg(p, fallback string) string {
	i := strings.Index(p, "/node_modules/")
	if i < 0 {
		return fallback
	}
	parts := strings.Split(p[i+len("/node_modules/"):], "/")
	switch {
	case len(parts) == 0 || parts[0] == "" || parts[0] == ".bin":
		return fallback
	case strings.HasPrefix(parts[0], "@") && len(parts) > 1:
		return parts[0] + "/" + parts[1]
	}
	return parts[0]
}
