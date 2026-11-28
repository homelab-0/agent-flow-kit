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
	LoginNote string    `toml:"login_note"`
	PolicyURL string    `toml:"policy_url"`
	Models    []string  `toml:"models"` // hints, not a list AFK routes from
	Auth      Auth      `toml:"auth"`
	ModelList ModelList `toml:"model_list"`
	Modes     Modes     `toml:"modes"`
	Skills    Skills    `toml:"skills"`
	MCP       MCP       `toml:"mcp"`
}

// MCP is where a harness reads its user-level MCP servers. AFK writes the
// servers in mcp.toml there; an empty file means AFK doesn't manage them.
type MCP struct {
	// File is the config file, with the same "~/", "$NAME/..." and "|"
	// rules as Skills.Dir.
	File string `toml:"file"`
	// Format is how the file holds servers: claude-json, codex-toml,
	// opencode-json, gemini-json or copilot-json.
	Format string `toml:"format"`
	// Verified is the CLI version the file and format were checked
	// against ("" for one taken from the CLI's documentation).
	Verified string `toml:"verified"`
	// ProjectFile is where it reads a repository's own servers, relative
	// to the repository, in the same format. ".mcp.json" means it reads
	// the repository's .mcp.json itself.
	ProjectFile string `toml:"project_file"`
}

// MCPFormats are the MCP config formats AFK can write.
var MCPFormats = []string{"claude-json", "codex-toml", "opencode-json", "gemini-json", "copilot-json"}

// Skills is where a harness reads its user-level skills. AFK syncs its
// central skills there; an empty dir means AFK doesn't manage them.
type Skills struct {
	// Dir is the skills directory: "~/" is the home directory, and
	// "$NAME/..." uses that variable when it is set (else the rest
	// after the first "|": "$CODEX_HOME/skills|~/.codex/skills").
	Dir string `toml:"dir"`
	// ProjectDir is where it reads a repository's own skills, relative
	// to the repository root. ".agents/skills" means it reads AFK's
	// project source itself, so nothing is copied.
	ProjectDir string `toml:"project_dir"`
	// Format is how a skill is laid out: "skill-md" (a folder with a
	// SKILL.md), the only one so far.
	Format string `toml:"format"`
	// Verified is the CLI version the directory was checked against
	// ("" for one taken from the CLI's documentation).
	Verified string `toml:"verified"`
}

// ModelList is how a harness says which models this account can use. AFK
// runs the command and reads the model names from its output; a harness
// with none is routed from the catalog alone.
type ModelList struct {
	// Command prints the models (the first word is the program).
	Command []string `toml:"command"`
	// Format is how to read the output: codex-json, grok-text, tsv or
	// lines.
	Format string `toml:"format"`
	// Verified is the CLI version the command was checked against.
	Verified string `toml:"verified"`
}

// ModelListFormats are the model list outputs AFK can read.
var ModelListFormats = []string{"codex-json", "grok-text", "tsv", "lines"}

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
	// UserConfig are the flags that keep the CLI to your own settings, so
	// it loads none from the directory it runs in (hooks, permission
	// rules, environment, MCP servers). AFK adds them to a one-shot run
	// in a directory you haven't trusted, where the CLI's own "trust this
	// folder?" question is never asked.
	UserConfig []string `toml:"user_config"`
	// ProjectConfig says when the CLI loads settings from the directory
	// it runs in: "trusted" when it does so only for a directory you
	// trusted in the CLI itself, "never" when it has none. "unknown" (or
	// nothing) means it may, and AFK says so when it can't stop it; an
	// override spells it "unknown" to undo a built-in "trusted".
	ProjectConfig string `toml:"project_config"`
	// ModeFlags are the CLI's other flags that change what it may do
	// without asking (its permission mode, sandbox, settings source or tool
	// allowlist). AFK sets the mode itself, so --pass refuses them unless
	// the run is yolo.
	ModeFlags []string `toml:"mode_flags"`
	// ConfigFlags take a key=value setting (Codex -c); ConfigKeys are the
	// settings among them that change the mode. --pass refuses those keys
	// (and any key below them) unless the run is yolo.
	ConfigFlags []string `toml:"config_flags"`
	ConfigKeys  []string `toml:"config_keys"`
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

// flagValue reports whether x is flag f, and the value attached to it
// (--flag=value, or -fvalue for a one-letter flag).
func flagValue(x, f string) (value string, attached, ok bool) {
	switch {
	case x == f:
		return "", false, true
	case strings.HasPrefix(x, f+"="):
		return x[len(f)+1:], true, true
	case len(f) == 2 && f[0] == '-' && f[1] != '-' && strings.HasPrefix(x, f) && len(x) > 2:
		return x[2:], true, true
	}
	return "", false, false
}

// ModeIn is the first argument in pass that would change the CLI's
// permission mode behind AFK's back: one of mode_flags, or a config_flags
// setting whose key is one of config_keys. "" when there is none. The
// CLI's yolo flags are YoloIn's.
func (m Manifest) ModeIn(pass []string) string {
	for i, x := range pass {
		for _, f := range m.Modes.ModeFlags {
			if _, _, ok := flagValue(x, f); ok {
				return f
			}
		}
		for _, f := range m.Modes.ConfigFlags {
			v, attached, ok := flagValue(x, f)
			if !ok {
				continue
			}
			if !attached {
				if i+1 >= len(pass) {
					continue
				}
				v = pass[i+1]
			}
			key, _, _ := strings.Cut(v, "=")
			key = strings.TrimSpace(key)
			for _, k := range m.Modes.ConfigKeys {
				if key == k || strings.HasPrefix(key, k+".") {
					return f + " " + key
				}
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
	if len(m.ModelList.Command) > 0 {
		if strings.TrimSpace(m.ModelList.Command[0]) == "" {
			return fmt.Errorf("%s: model_list.command needs a program", path)
		}
		ok := false
		for _, f := range ModelListFormats {
			ok = ok || f == m.ModelList.Format
		}
		if !ok {
			return fmt.Errorf("%s: model_list.format must be one of %s", path, strings.Join(ModelListFormats, ", "))
		}
	}
	switch m.Skills.Format {
	case "", "skill-md":
	default:
		return fmt.Errorf("%s: skills.format must be skill-md", path)
	}
	if d := m.Skills.ProjectDir; d != "" {
		c := filepath.ToSlash(filepath.Clean(d))
		if filepath.IsAbs(d) || strings.HasPrefix(d, "~") || c == "." || c == ".." || strings.HasPrefix(c, "../") {
			return fmt.Errorf("%s: skills.project_dir must be a folder inside the repository", path)
		}
	}
	if f := m.MCP.ProjectFile; f != "" {
		c := filepath.ToSlash(filepath.Clean(f))
		if filepath.IsAbs(f) || strings.HasPrefix(f, "~") || c == "." || c == ".." || strings.HasPrefix(c, "../") {
			return fmt.Errorf("%s: mcp.project_file must be a file inside the repository", path)
		}
	}
	if f := m.MCP.Format; f != "" {
		ok := false
		for _, x := range MCPFormats {
			ok = ok || f == x
		}
		if !ok {
			return fmt.Errorf("%s: mcp.format must be one of %s", path, strings.Join(MCPFormats, ", "))
		}
		if m.MCP.File == "" {
			return fmt.Errorf("%s: mcp.format needs mcp.file", path)
		}
	}
	switch m.Modes.ProjectConfig {
	case "", "unknown", "trusted", "never":
	default:
		return fmt.Errorf("%s: modes.project_config must be trusted, never or unknown", path)
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
	list(&base.ModelList.Command, over.ModelList.Command)
	set(&base.ModelList.Format, over.ModelList.Format)
	set(&base.ModelList.Verified, over.ModelList.Verified)
	set(&base.Skills.Dir, over.Skills.Dir)
	set(&base.Skills.ProjectDir, over.Skills.ProjectDir)
	set(&base.Skills.Format, over.Skills.Format)
	set(&base.Skills.Verified, over.Skills.Verified)
	set(&base.MCP.File, over.MCP.File)
	set(&base.MCP.Format, over.MCP.Format)
	set(&base.MCP.Verified, over.MCP.Verified)
	set(&base.MCP.ProjectFile, over.MCP.ProjectFile)
	o := over.Modes
	set(&base.Modes.Verified, o.Verified)
	list(&base.Modes.BypassFlags, o.BypassFlags)
	list(&base.Modes.DirFlags, o.DirFlags)
	list(&base.Modes.UserConfig, o.UserConfig)
	set(&base.Modes.ProjectConfig, o.ProjectConfig)
	list(&base.Modes.ModeFlags, o.ModeFlags)
	list(&base.Modes.ConfigFlags, o.ConfigFlags)
	list(&base.Modes.ConfigKeys, o.ConfigKeys)
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

// SkillsDir is where a harness reads its skills on this machine ("" when
// AFK doesn't manage them).
func (m Manifest) SkillsDir(e Env) string { return e.expandPath(m.Skills.Dir) }

// MCPFile is the file a harness reads its MCP servers from on this
// machine ("" when AFK doesn't manage them).
func (m Manifest) MCPFile(e Env) string {
	if m.MCP.Format == "" {
		return ""
	}
	return e.expandPath(m.MCP.File)
}

// expandPath picks the first alternative of "a|b" that applies here.
func (e Env) expandPath(spec string) string {
	for _, alt := range strings.Split(spec, "|") {
		alt = strings.TrimSpace(alt)
		switch {
		case alt == "":
		case strings.HasPrefix(alt, "~/"):
			return e.home(strings.TrimPrefix(alt, "~/"))
		case strings.HasPrefix(alt, "$"):
			name, rest, _ := strings.Cut(alt[1:], "/")
			if v := e.getenv(name); v != "" && filepath.IsAbs(v) {
				return filepath.Join(v, rest)
			}
		case filepath.IsAbs(alt):
			return alt
		}
	}
	return ""
}
