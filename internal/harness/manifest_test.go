package harness

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestEveryManifestLoads(t *testing.T) {
	for _, n := range order {
		m, ok := ManifestFor(n)
		if !ok || m.Name != n || m.Display == "" || len(m.Bins) == 0 {
			t.Errorf("%s: %+v", n, m)
		}
	}
	if len(All()) != len(order) {
		t.Errorf("registry has %d, manifests %d", len(All()), len(order))
	}
}

// The flags for each mode, per CLI, as checked against each CLI's --help.
func TestModeFlags(t *testing.T) {
	type want struct {
		flags      []string
		mode, note string
	}
	cases := map[string]map[string]want{
		"claude": {
			"read-only": {[]string{"--permission-mode", "plan"}, "read-only", ""},
			"ask":       {[]string{"--permission-mode", "manual"}, "ask", ""},
			"edits":     {[]string{"--permission-mode", "acceptEdits"}, "edits", ""},
			"auto":      {[]string{"--permission-mode", "auto"}, "auto", ""},
			"yolo":      {[]string{"--dangerously-skip-permissions"}, "yolo", ""},
		},
		"codex": {
			"read-only": {[]string{"--sandbox", "read-only", "--ask-for-approval", "never"}, "read-only", ""},
			"ask":       {[]string{"--sandbox", "read-only", "--ask-for-approval", "on-request"}, "ask", ""},
			"edits":     {[]string{"--sandbox", "read-only", "--ask-for-approval", "on-request"}, "ask", "codex: can't run in edits, running in ask"},
			"auto":      {[]string{"--sandbox", "workspace-write", "--ask-for-approval", "never"}, "auto", ""},
			"yolo":      {[]string{"--dangerously-bypass-approvals-and-sandbox"}, "yolo", ""},
		},
		"grok": {
			"ask":   {[]string{"--permission-mode", "default"}, "ask", ""},
			"edits": {[]string{"--permission-mode", "acceptEdits"}, "edits", ""},
			"yolo":  {[]string{"--always-approve"}, "yolo", ""},
		},
		"agy": {
			"read-only": {[]string{"--mode", "plan"}, "read-only", ""},
			"auto":      {[]string{"--mode", "auto"}, "auto", ""},
		},
		"opencode": {
			"auto": {[]string{}, "ask", "opencode: can't run in auto, running in ask"},
			"yolo": {[]string{}, "ask", "opencode: can't run in yolo, running in ask"},
		},
		"pi": {
			"ask":  {[]string{"--tools", "read,grep,find,ls"}, "read-only", "pi: can't run in ask, running in read-only"},
			"auto": {[]string{"--tools", "read,grep,find,ls,edit,write"}, "edits", "pi: can't run in auto, running in edits"},
			"yolo": {[]string{}, "yolo", ""},
		},
	}
	for h, modes := range cases {
		m, _ := ManifestFor(h)
		for mode, w := range modes {
			flags, ran, note, ok := m.ModeFlags(mode, false)
			if !ok || !reflect.DeepEqual(flags, w.flags) || ran != w.mode || note != w.note {
				t.Errorf("%s %s: %q %s %q %v, want %q %s %q", h, mode, flags, ran, note, ok, w.flags, w.mode, w.note)
			}
		}
	}
	// One-shot tables.
	codex, _ := ManifestFor("codex")
	if f, ran, _, _ := codex.ModeFlags("auto", true); !reflect.DeepEqual(f, []string{"--sandbox", "workspace-write"}) || ran != "auto" {
		t.Errorf("codex exec auto: %q", f)
	}
	oc, _ := ManifestFor("opencode")
	if f, ran, _, _ := oc.ModeFlags("yolo", true); !reflect.DeepEqual(f, []string{"--auto"}) || ran != "yolo" {
		t.Errorf("opencode run yolo: %q", f)
	}
}

// A CLI never runs looser than asked: with nothing as strict, it can't run.
func TestNeverLooser(t *testing.T) {
	oc, _ := ManifestFor("opencode")
	if _, _, note, ok := oc.ModeFlags("read-only", false); ok || !strings.Contains(note, "can't run in read-only") {
		t.Fatalf("opencode read-only: %q %v", note, ok)
	}
	for _, n := range order {
		m, _ := ManifestFor(n)
		for _, mode := range PermissionModes {
			if _, ran, _, ok := m.ModeFlags(mode, false); ok && ModeRank(ran) > ModeRank(mode) {
				t.Errorf("%s: %s ran as the looser %s", n, mode, ran)
			}
		}
	}
	m, _ := ManifestFor("claude")
	if _, _, _, ok := m.ModeFlags("reckless", false); ok {
		t.Error("an unknown mode was accepted")
	}
}

func TestOverrides(t *testing.T) {
	defer func() { manifests = loadEmbedded(); rebuild() }()
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("claude.toml", "name = \"claude\"\n[modes]\nverified = \"9.9\"\nauto = [\"--permission-mode\", \"acceptEdits\"]\n")
	write("notes.txt", "ignored")
	write("zed.toml", "name = \"zed\"\n")
	warns, err := LoadOverrides(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(warns) != 1 || !strings.Contains(warns[0], "zed") {
		t.Errorf("warnings %v", warns)
	}
	m, _ := ManifestFor("claude")
	if f, _, _, _ := m.ModeFlags("auto", false); !reflect.DeepEqual(f, []string{"--permission-mode", "acceptEdits"}) || m.Modes.Verified != "9.9" {
		t.Fatalf("override not applied: %+v", m.Modes)
	}
	// The rest of the default stays.
	if f, _, _, _ := m.ModeFlags("yolo", false); !reflect.DeepEqual(f, []string{"--dangerously-skip-permissions"}) || m.Display != "Claude Code" {
		t.Fatalf("defaults lost: %+v", m)
	}
	if a, _ := Lookup("claude"); a.Manifest.Modes.Verified != "9.9" {
		t.Fatal("the registry was not rebuilt")
	}
	// Bad files are errors naming the file.
	for name, body := range map[string]string{
		"codex.toml": "name = \"codex\"\nflavour = 1\n",
		"grok.toml":  "name = \"agy\"\n",
		"agy.toml":   "name = \"agy\"\nbins = \"agy\"\n",
	} {
		bad := t.TempDir()
		if err := os.WriteFile(filepath.Join(bad, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadOverrides(bad); err == nil || !strings.Contains(err.Error(), name) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := LoadOverrides(filepath.Join(dir, "missing")); err != nil {
		t.Errorf("a missing directory: %v", err)
	}
}

// A [modes.print] override changes only the entries it sets.
func TestPrintOverrideMerges(t *testing.T) {
	defer func() { manifests = loadEmbedded(); rebuild() }()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex.toml"), []byte("name = \"codex\"\n[modes.print]\nauto = [\"--sandbox\", \"read-only\"]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOverrides(dir); err != nil {
		t.Fatal(err)
	}
	m, _ := ManifestFor("codex")
	if f, _, _, _ := m.ModeFlags("auto", true); !reflect.DeepEqual(f, []string{"--sandbox", "read-only"}) {
		t.Errorf("auto: %q", f)
	}
	if f, ran, _, ok := m.ModeFlags("read-only", true); !ok || ran != "read-only" || !reflect.DeepEqual(f, []string{"--sandbox", "read-only"}) {
		t.Errorf("read-only lost: %q %s %v", f, ran, ok)
	}
	if f, _, _, _ := m.ModeFlags("yolo", true); !reflect.DeepEqual(f, []string{"--dangerously-bypass-approvals-and-sandbox"}) {
		t.Errorf("yolo lost: %q", f)
	}
}

func TestYoloIn(t *testing.T) {
	claude, _ := ManifestFor("claude")
	grok, _ := ManifestFor("grok")
	codex, _ := ManifestFor("codex")
	pi, _ := ManifestFor("pi")
	for _, c := range []struct {
		m    Manifest
		pass []string
		want bool
	}{
		{claude, []string{"--dangerously-skip-permissions"}, true},
		{claude, []string{"--verbose"}, false},
		{grok, []string{"--always-approve"}, true},
		{codex, []string{"--dangerously-bypass-approvals-and-sandbox"}, true},
		{codex, []string{"--yolo"}, true},
		{pi, []string{"--tools", "x"}, false},
	} {
		if got := c.m.YoloIn(c.pass); got != c.want {
			t.Errorf("%s %q: %v", c.m.Name, c.pass, got)
		}
	}
}

func TestStripYoloAndDirIn(t *testing.T) {
	codex, _ := ManifestFor("codex")
	if got := codex.StripYolo([]string{"--yolo", "-c", "x=1", "--dangerously-bypass-approvals-and-sandbox"}); !reflect.DeepEqual(got, []string{"-c", "x=1"}) {
		t.Errorf("strip: %q", got)
	}
	for _, pass := range [][]string{{"--cd", "/x"}, {"--cd=/x"}, {"-C", "/x"}, {"-C/x"}} {
		if codex.DirIn(pass) == "" {
			t.Errorf("%q: no directory flag found", pass)
		}
	}
	if d := codex.DirIn([]string{"-c", "x=1"}); d != "" {
		t.Errorf("-c taken for -C: %q", d)
	}
	// codex exec can't ask: one-shot ask runs read-only, and says so.
	if f, ran, note, _ := codex.ModeFlags("ask", true); ran != "read-only" || !reflect.DeepEqual(f, []string{"--sandbox", "read-only"}) || note == "" {
		t.Errorf("codex exec ask: %q %s %q", f, ran, note)
	}
}
