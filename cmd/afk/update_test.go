package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestUpdateIsACommandOnlyWithoutAPrompt(t *testing.T) {
	for _, argv := range [][]string{{"update"}, {"update", "--check"}, {"update", "-y", "--dry-run"}} {
		if !isUpdateCommand(argv) {
			t.Errorf("%v should be the command", argv)
		}
	}
	for _, argv := range [][]string{{"update", "the", "README"}, {"update the README"}, {"fix", "update"}, nil} {
		if isUpdateCommand(argv) {
			t.Errorf("%v is a prompt", argv)
		}
	}
}

func TestSelfInstallReadsTheMethodFromThePath(t *testing.T) {
	for _, c := range []struct{ exe, resolved, method, want string }{
		{"/usr/local/bin/afk", "/usr/local/lib/node_modules/@homelab0/afk/node_modules/@homelab0/afk-linux-x64/bin/afk", "npm", "npm install -g @homelab0/afk@0.5.0"},
		{"/home/me/.bun/bin/afk", "/home/me/.bun/install/global/node_modules/@homelab0/afk-linux-x64/bin/afk", "bun", "bun add -g @homelab0/afk@0.5.0"},
		{"/home/me/.local/share/pnpm/afk", "/home/me/.local/share/pnpm/global/5/node_modules/@homelab0/afk-linux-x64/bin/afk", "pnpm", "pnpm add -g @homelab0/afk@0.5.0"},
		{"/home/me/go/bin/afk", "/home/me/go/bin/afk", "go", "go install github.com/homelab-0/agent-flow-kit/cmd/afk@v0.5.0"},
		{"/home/me/.npm/_npx/abc/node_modules/@homelab0/afk-linux-x64/bin/afk", "", "npx", ""},
		{"/opt/afk/afk", "/opt/afk/afk", "self-managed", ""},
		{"/home/me/.local/share/mise/shims/afk", "/home/me/.local/share/mise/installs/npm-homelab0-afk/0.4.0/lib/node_modules/@homelab0/afk-linux-x64/bin/afk", "mise", ""},
	} {
		method, command, note := selfInstall(c.exe, c.resolved, "/home/me")
		got := ""
		if command != nil {
			got = strings.Join(command("0.5.0"), " ")
		}
		if method != c.method || got != c.want || (command == nil) != (note != "") {
			t.Errorf("%s: %s %q (note %q), want %s %q", c.exe, method, got, note, c.method, c.want)
		}
	}
}

func TestAfkUpdate(t *testing.T) {
	const npmExe = "/usr/local/lib/node_modules/@homelab0/afk-linux-x64/bin/afk"
	run := func(have, exe string, yes bool, argv ...string) (*fakeOps, int, string, string) {
		f := newFake(t, nil)
		f.yes = yes
		f.answer["npm view"] = npmView("0.5.0")
		var out, errb bytes.Buffer
		code := selfUpdate(f.ops(), have, exe, exe, "/home/me", argv, &out, &errb)
		return f, code, out.String(), errb.String()
	}
	installs := func(f *fakeOps) []string {
		var got []string
		for _, r := range f.ran {
			if len(r) > 1 && r[1] != "view" {
				got = append(got, strings.Join(r, " "))
			}
		}
		return got
	}
	// Already the newest: nothing is run.
	if f, code, out, _ := run("0.5.0", npmExe, true); code != 0 || !strings.Contains(out, "is the newest") || len(installs(f)) != 0 {
		t.Errorf("newest: %d %q %v", code, out, f.ran)
	}
	// npm's notices around its answer don't hide the version.
	noisy := newFake(t, nil)
	noisy.answer["npm view"] = func(a []string) ([]byte, int) {
		b, c := npmView("0.5.0")(a)
		return append(append([]byte("npm warn config something\n"), b...), []byte("\nnpm notice New minor version of npm available\n")...), c
	}
	var no, ne bytes.Buffer
	if code := selfUpdate(noisy.ops(), "0.4.0", npmExe, npmExe, "/home/me", []string{"--check"}, &no, &ne); code != 0 || !strings.Contains(no.String(), "afk 0.5.0 is out") {
		t.Errorf("noisy npm: %d %q %q", code, no.String(), ne.String())
	}
	// --check and --dry-run change nothing.
	for _, flag := range []string{"--check", "--dry-run"} {
		if f, code, out, _ := run("0.4.0", npmExe, true, flag); code != 0 || !strings.Contains(out, "afk 0.5.0 is out") || len(installs(f)) != 0 {
			t.Errorf("%s: %d %q %v", flag, code, out, f.ran)
		}
	}
	// A no leaves it alone; a yes runs the pinned install.
	if f, code, out, _ := run("0.4.0", npmExe, false); code != 1 || !strings.Contains(out, "Nothing was changed") || len(installs(f)) != 0 {
		t.Errorf("no: %d %q %v", code, out, f.ran)
	}
	f, code, out, _ := run("0.4.0", npmExe, true)
	if got := installs(f); code != 0 || len(got) != 1 || got[0] != "npm install -g @homelab0/afk@0.5.0" || !strings.Contains(out, "Updated to afk 0.5.0") {
		t.Errorf("yes: %d %q %v", code, out, got)
	}
	// A build AFK can't replace says how to get the new one.
	if f, code, _, errs := run("0.4.0", "/opt/afk/afk", true); code != 1 || !strings.Contains(errs, "releases") || len(installs(f)) != 0 {
		t.Errorf("self-managed: %d %q", code, errs)
	}
	// Nobody to ask and no -y: nothing is run.
	fk := newFake(t, nil)
	fk.tty = false
	fk.answer["npm view"] = npmView("0.5.0")
	var o, e bytes.Buffer
	if code := selfUpdate(fk.ops(), "0.4.0", npmExe, npmExe, "/home/me", nil, &o, &e); code != 2 || len(installs(fk)) != 0 {
		t.Errorf("no terminal: %d %v", code, fk.ran)
	}
}
