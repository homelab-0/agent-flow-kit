package harness

import (
	"bytes"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	toml "github.com/pelletier/go-toml/v2"
)

// Manifest is one harness described as data: what it is called, how it is
// found and signed in to, and the flags that give each AFK permission mode.
// The defaults are embedded (manifests/*.toml); a file of the same name in
// ~/.config/afk/harnesses/ overrides the fields it sets.
type Manifest struct {
	Name       string   `toml:"name"`
	Display    string   `toml:"display"`
	Vendor     string   `toml:"vendor"`
	Bins       []string `toml:"bins"`
	NPMPackage string   `toml:"npm_package"`
	Efforts    []string `toml:"efforts"`
	EffortFlag string   `toml:"effort_flag"`
	SelfUpdate string   `toml:"self_update"`
	// LoginNote is shown instead of a login command when signing in has
	// no single command ("pi (then /login)").
	LoginNote string   `toml:"login_note"`
	PolicyURL string   `toml:"policy_url"`
	Models    []string `toml:"models"` // hints, not a list AFK routes from
	Auth      Auth     `toml:"auth"`
	Modes     Modes    `toml:"modes"`
}

// Auth is how a harness signs in. AFK only runs these commands and reads
// their exit code; it never reads the credentials they write.
type Auth struct {
	Login       []string `toml:"login"`
	DeviceLogin []string `toml:"device_login"`
	// Status exits 0 when signed in. Only the exit code counts.
	Status []string `toml:"status"`
	// Expiry is a command of the harness that reports when its login
	// expires, when it has one.
	Expiry []string `toml:"expiry"`
	// Errors are words in a failed run's output that mean the login is
	// gone.
	Errors []string `toml:"errors"`
}

// Modes are the flags for each permission mode. A mode a harness can't do
// is left out; AFK then runs the next stricter mode it can do. Print, when
// set, replaces the table for one-shot (-p) runs.
type Modes struct {
	Verified string     `toml:"verified"` // the CLI version the flags were checked against
	ReadOnly *[]string  `toml:"read-only"`
	Ask      *[]string  `toml:"ask"`
	Edits    *[]string  `toml:"edits"`
	Auto     *[]string  `toml:"auto"`
	Yolo     *[]string  `toml:"yolo"`
	Print    *ModeFlags `toml:"print"`
	// BypassFlags are other spellings of the yolo flag (aliases): given
	// through --pass, they make the run yolo too.
	BypassFlags []string `toml:"bypass_flags"`
	// DirFlags are the CLI's flags that choose another working directory;
	// yolo refuses them in --pass, because trust is checked where afk runs.
	DirFlags []string `toml:"dir_flags"`
}

// ModeFlags is a mode table without the version.
type ModeFlags struct {
	ReadOnly *[]string `toml:"read-only"`
	Ask      *[]string `toml:"ask"`
	Edits    *[]string `toml:"edits"`
	Auto     *[]string `toml:"auto"`
	Yolo     *[]string `toml:"yolo"`
}

// PermissionModes are AFK's modes, strictest first.
var PermissionModes = []string{"read-only", "ask", "edits", "auto", "yolo"}

// ModeRank is a mode's place in PermissionModes, -1 for an unknown mode.
func ModeRank(m string) int {
	for i, x := range PermissionModes {
		if x == m {
			return i
		}
	}
	return -1
}

func (f ModeFlags) get(mode string) (*[]string, bool) {
	var p *[]string
	switch mode {
	case "read-only":
		p = f.ReadOnly
	case "ask":
		p = f.Ask
	case "edits":
		p = f.Edits
	case "auto":
		p = f.Auto
	case "yolo":
		p = f.Yolo
	}
	return p, p != nil
}

func (m Modes) table(print bool) ModeFlags {
	if print && m.Print != nil {
		return *m.Print
	}
	return ModeFlags{ReadOnly: m.ReadOnly, Ask: m.Ask, Edits: m.Edits, Auto: m.Auto, Yolo: m.Yolo}
}

// HasModes reports whether the manifest says how to run the CLI in any
// mode (CLIs AFK doesn't launch have no table).
func (m Manifest) HasModes() bool {
	t := m.Modes.table(false)
	for _, mode := range PermissionModes {
		if _, ok := t.get(mode); ok {
			return true
		}
	}
	return false
}

// yoloRuns are the argument runs that turn on the CLI's yolo: its yolo
// flags from either table, and each bypass alias.
func (m Manifest) yoloRuns() [][]string {
	var runs [][]string
	for _, print := range []bool{false, true} {
		if f, ok := m.Modes.table(print).get("yolo"); ok && len(*f) > 0 {
			runs = append(runs, *f)
		}
	}
	for _, b := range m.Modes.BypassFlags {
		runs = append(runs, []string{b})
	}
	return runs
}

// matchAt reports how many arguments of pass, from i, are the run (as
// given, or as --flag=value for a one-flag run), or 0.
func matchAt(pass []string, i int, run []string) int {
	if i+len(run) > len(pass) {
		return 0
	}
	for j, x := range run {
		if pass[i+j] != x && !(len(run) == 1 && strings.HasPrefix(pass[i+j], x+"=")) {
			return 0
		}
	}
	return len(run)
}

// YoloIn reports whether pass holds the CLI's own yolo flags.
func (m Manifest) YoloIn(pass []string) bool {
	for i := range pass {
		for _, run := range m.yoloRuns() {
			if matchAt(pass, i, run) > 0 {
				return true
			}
		}
	}
	return false
}

// StripYolo is pass without the CLI's own yolo flags.
func (m Manifest) StripYolo(pass []string) []string {
	var out []string
	for i := 0; i < len(pass); {
		n := 0
		for _, run := range m.yoloRuns() {
			if n = matchAt(pass, i, run); n > 0 {
				break
			}
		}
		if n > 0 {
			i += n
			continue
		}
		out = append(out, pass[i])
		i++
	}
	return out
}

// DirIn is the first flag in pass that chooses another working directory,
// or "".
func (m Manifest) DirIn(pass []string) string {
	for _, x := range pass {
		for _, d := range m.Modes.DirFlags {
			if x == d || strings.HasPrefix(x, d+"=") || (len(d) == 2 && d[0] == '-' && d[1] != '-' && strings.HasPrefix(x, d) && len(x) > 2) {
				return d
			}
		}
	}
	return ""
}

// ModeFlags works out the flags for a requested mode. When the CLI can't
// do it, the next stricter mode it can do is used (never a looser one):
// mode is what runs and note says why it differs. ok is false when the CLI
// can do nothing as strict as asked.
func (m Manifest) ModeFlags(requested string, print bool) (flags []string, mode, note string, ok bool) {
	r := ModeRank(requested)
	if r < 0 {
		return nil, "", "", false
	}
	t := m.Modes.table(print)
	for i := r; i >= 0; i-- {
		if f, has := t.get(PermissionModes[i]); has {
			mode = PermissionModes[i]
			if mode != requested {
				note = fmt.Sprintf("%s: can't run in %s, running in %s", m.Name, requested, mode)
			}
			return append([]string{}, (*f)...), mode, note, true
		}
	}
	return nil, "", fmt.Sprintf("%s: can't run in %s or anything stricter", m.Name, requested), false
}

//go:embed manifests/*.toml
var embedded embed.FS

// order is the order harnesses are listed in.
var order = []string{"claude", "codex", "opencode", "grok", "agy", "gemini", "copilot", "cursor", "kiro", "qwen", "kimi", "pi", "devin"}

func loadEmbedded() map[string]Manifest {
	out := map[string]Manifest{}
	for _, n := range order {
		b, err := embedded.ReadFile("manifests/" + n + ".toml")
		if err != nil {
			panic("harness manifest missing: " + n)
		}
		m, err := parseManifest("manifests/"+n+".toml", b, true)
		if err != nil {
			panic(err)
		}
		out[n] = m
	}
	return out
}

func parseManifest(path string, b []byte, strict bool) (Manifest, error) {
	var m Manifest
	dec := toml.NewDecoder(bytes.NewReader(b))
	if strict {
		dec = dec.DisallowUnknownFields()
	}
	if err := dec.Decode(&m); err != nil {
		var de *toml.DecodeError
		if errors.As(err, &de) {
			row, _ := de.Position()
			return m, fmt.Errorf("%s:%d: %s", path, row, de.Error())
		}
		var sm *toml.StrictMissingError
		if errors.As(err, &sm) && len(sm.Errors) > 0 {
			row, _ := sm.Errors[0].Position()
			return m, fmt.Errorf("%s:%d: %s is not a manifest field", path, row, strings.Join(sm.Errors[0].Key(), "."))
		}
		return m, fmt.Errorf("%s: %w", path, err)
	}
	return m, m.validate(path)
}

func (m Manifest) validate(path string) error {
	if m.Name == "" {
		return fmt.Errorf("%s: name is required", path)
	}
	for _, f := range [][]string{m.Auth.Login, m.Auth.DeviceLogin, m.Auth.Status, m.Auth.Expiry} {
		if len(f) > 0 && strings.TrimSpace(f[0]) == "" {
			return fmt.Errorf("%s: an auth command needs a program", path)
		}
	}
	for _, t := range []ModeFlags{m.Modes.table(false), m.Modes.table(true)} {
		for _, mode := range PermissionModes {
			if f, ok := t.get(mode); ok {
				for _, a := range *f {
					if strings.ContainsAny(a, "\n\x00") {
						return fmt.Errorf("%s: modes.%s has a flag with a newline", path, mode)
					}
				}
			}
		}
	}
	return nil
}

// merge lays the fields an override sets over the default.
func merge(base, over Manifest) Manifest {
	set := func(dst *string, v string) {
		if v != "" {
			*dst = v
		}
	}
	list := func(dst *[]string, v []string) {
		if v != nil {
			*dst = v
		}
	}
	set(&base.Display, over.Display)
	set(&base.Vendor, over.Vendor)
	list(&base.Bins, over.Bins)
	set(&base.NPMPackage, over.NPMPackage)
	list(&base.Efforts, over.Efforts)
	set(&base.EffortFlag, over.EffortFlag)
	set(&base.SelfUpdate, over.SelfUpdate)
	set(&base.LoginNote, over.LoginNote)
	set(&base.PolicyURL, over.PolicyURL)
	list(&base.Models, over.Models)
	list(&base.Auth.Login, over.Auth.Login)
	list(&base.Auth.DeviceLogin, over.Auth.DeviceLogin)
	list(&base.Auth.Status, over.Auth.Status)
	list(&base.Auth.Expiry, over.Auth.Expiry)
	list(&base.Auth.Errors, over.Auth.Errors)
	o := over.Modes
	set(&base.Modes.Verified, o.Verified)
	list(&base.Modes.BypassFlags, o.BypassFlags)
	list(&base.Modes.DirFlags, o.DirFlags)
	for _, p := range []struct{ dst, src **[]string }{
		{&base.Modes.ReadOnly, &o.ReadOnly}, {&base.Modes.Ask, &o.Ask}, {&base.Modes.Edits, &o.Edits},
		{&base.Modes.Auto, &o.Auto}, {&base.Modes.Yolo, &o.Yolo},
	} {
		if *p.src != nil {
			*p.dst = *p.src
		}
	}
	if o.Print != nil {
		// Field by field over the print table in effect, on a copy so the
		// built-in table is left as it is.
		t := base.Modes.table(true)
		for _, p := range []struct{ dst, src **[]string }{
			{&t.ReadOnly, &o.Print.ReadOnly}, {&t.Ask, &o.Print.Ask}, {&t.Edits, &o.Print.Edits},
			{&t.Auto, &o.Print.Auto}, {&t.Yolo, &o.Print.Yolo},
		} {
			if *p.src != nil {
				*p.dst = *p.src
			}
		}
		base.Modes.Print = &t
	}
	return base
}

// LoadOverrides reads ~/.config/afk/harnesses/*.toml (dir) over the
// embedded manifests. A file that doesn't parse or validate is an error
// naming it; a file for a harness AFK doesn't know adds nothing (it is
// reported). Overrides apply for the rest of the process.
func LoadOverrides(dir string) (warnings []string, err error) {
	ents, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	next := map[string]Manifest{}
	for k, v := range manifests {
		next[k] = v
	}
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".toml") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		over, err := parseManifest(path, b, true)
		if err != nil {
			return nil, err
		}
		if want := strings.TrimSuffix(e.Name(), ".toml"); over.Name != want {
			return nil, fmt.Errorf("%s: name = %q must match the file name %q", path, over.Name, want)
		}
		base, ok := next[over.Name]
		if !ok {
			warnings = append(warnings, fmt.Sprintf("%s: AFK doesn't know a harness called %s; ignored", path, over.Name))
			continue
		}
		next[over.Name] = merge(base, over)
	}
	manifests = next
	rebuild()
	return warnings, nil
}

// manifests is the loaded set, by name.
var manifests = loadEmbedded()

// ManifestFor returns a harness's manifest.
func ManifestFor(name string) (Manifest, bool) {
	m, ok := manifests[name]
	return m, ok
}
