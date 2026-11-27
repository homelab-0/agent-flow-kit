package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

func sampleReport() harness.Report {
	return harness.Report{Schema: harness.Schema, OS: "linux", Harnesses: []harness.Info{
		{Name: "claude", Installed: true, Healthy: true, Version: "2.1.0", Auth: harness.AuthOK,
			InstallMethod: "npm", Package: "@anthropic-ai/claude-code", Efforts: []string{"low", "max"}},
		{Name: "grok", Installed: true, Healthy: false, Problem: "--version failed: boom", Auth: harness.AuthSignedOut,
			Login: "grok login", InstallMethod: "self-managed", Efforts: []string{}},
		{Name: "gemini", Auth: harness.AuthNotInstalled, Efforts: []string{}},
	}}
}

func TestRenderHarnessesPlain(t *testing.T) {
	out := renderHarnesses(sampleReport(), false, false, true)
	for _, want := range []string{
		"2 of 3 supported CLIs installed",
		"claude  2.1.0    authenticated  npm (@anthropic-ai/claude-code)  low..max",
		"grok    n/e      signed_out     self-managed",
		"grok: --version failed: boom",
		"grok: not signed in; sign in with: grok login",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if strings.Contains(out, "gemini") {
		t.Error("an uninstalled CLI is listed without --all")
	}
	if strings.Contains(out, "\x1b[") {
		t.Error("colour codes without colour")
	}
	if !strings.Contains(renderHarnesses(sampleReport(), true, false, true), "gemini") {
		t.Error("--all leaves out the uninstalled CLI")
	}
}

func TestHarnessCmdRejectsUnknownArgs(t *testing.T) {
	var out, errb bytes.Buffer
	if code := harnessCmd([]string{"--bogus"}, &out, &errb); code != 2 || !strings.Contains(errb.String(), `unknown argument "--bogus"`) {
		t.Fatalf("code %d, stderr %q", code, errb.String())
	}
	out.Reset()
	if code := harnessCmd([]string{"--help"}, &out, &errb); code != 0 || !strings.Contains(out.String(), "Usage: afk harness") {
		t.Fatalf("help: %d %q", code, out.String())
	}
}
