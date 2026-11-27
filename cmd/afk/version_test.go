package main

import (
	"bytes"
	"runtime/debug"
	"strings"
	"testing"
)

func TestBuildVersion(t *testing.T) {
	defer func(v, c, d string) { version, commit, date = v, c, d }(version, commit, date)

	version, commit, date = "", "", ""
	if v, c, d := buildVersion(nil, false); v != "dev" || c != "" || d != "" {
		t.Errorf("no info: %q %q %q", v, c, d)
	}
	info := &debug.BuildInfo{Main: debug.Module{Version: "v0.1.0"}, Settings: []debug.BuildSetting{
		{Key: "vcs.revision", Value: "0123456789abcdef0123"}, {Key: "vcs.time", Value: "2026-11-27T00:00:00Z"},
	}}
	if v, c, d := buildVersion(info, true); v != "v0.1.0" || c != "0123456789ab" || d != "2026-11-27T00:00:00Z" {
		t.Errorf("build info: %q %q %q", v, c, d)
	}
	devel := &debug.BuildInfo{Main: debug.Module{Version: "(devel)"}}
	if v, _, _ := buildVersion(devel, true); v != "dev" {
		t.Errorf("devel: %q", v)
	}
	version, commit, date = "0.1.0", "abc123", "2026-11-28"
	if v, c, d := buildVersion(info, true); v != "0.1.0" || c != "abc123" || d != "2026-11-28" {
		t.Errorf("ldflags win: %q %q %q", v, c, d)
	}
}

func TestVersionCommand(t *testing.T) {
	var out, errb bytes.Buffer
	if versionCmd(nil, &out, &errb) != 0 || !strings.HasPrefix(out.String(), "afk ") {
		t.Errorf("version: %q", out.String())
	}
	if versionCmd([]string{"x"}, &out, &errb) != 2 {
		t.Error("extra words should be a usage error")
	}
}
