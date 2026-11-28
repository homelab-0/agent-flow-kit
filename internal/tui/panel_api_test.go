package tui

import (
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// tap sends keys to a panel, running each command the panel returns
// once (a save, then the reload it asks for).
func tap(p *Panel, keys ...string) {
	for _, k := range keys {
		cmd := p.key(k)
		for i := 0; cmd != nil && i < 3; i++ {
			msg := cmd()
			if _, ok := msg.(tea.BatchMsg); ok {
				break
			}
			cmd = p.Update(msg)
		}
	}
}

func TestAPITabShowsServerAndKeys(t *testing.T) {
	p := panelAt(t, TabAPI)
	p.Update(tea.WindowSizeMsg{Width: 110, Height: 30})
	s := panelText(p)
	for _, want := range []string{"8 API", "○ stopped", "will listen on 127.0.0.1:8484", "Sign-ins  ○ off",
		"▌  litellm", "AFK picks", "Grok only", "edits in /srv/work", "answer only",
		"afk_1a2b3c4d_…", "http://127.0.0.1:8484/v1", "afk/auto, or afk/<task>", "Last run    5m ago", "new key", "start"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}
	// A harness key says why it won't answer while sign-ins are off.
	tap(p, "down")
	if s := panelText(p); !strings.Contains(s, "It won't answer yet: sign-ins are off") {
		t.Errorf("no note on the harness key:\n%s", s)
	}
}

func TestAPITabMakesAKeyAndShowsItOnce(t *testing.T) {
	p := panelAt(t, TabAPI)
	src := p.src.(*fakePanel)
	tap(p, "n", "h", "s", "enter")
	if s := panelText(p); !strings.Contains(s, "What may hs reach?") || !strings.Contains(s, "Any (AFK picks)") {
		t.Fatalf("no kind choice:\n%s", s)
	}
	// A key for one CLI asks first, with the vendor-terms note.
	tap(p, "down", "enter")
	if s := panelText(p); !strings.Contains(s, "use your Grok sign-in through AFK") || !strings.Contains(s, "make the key") {
		t.Fatalf("no warning before a harness key:\n%s", s)
	}
	if len(src.ran) != 0 {
		t.Fatalf("made before the answer: %v", src.ran)
	}
	tap(p, "enter")
	if want := [][]string{{"api", "add", "hs", "grok"}}; !reflect.DeepEqual(src.ran, want) {
		t.Fatalf("ran %v", src.ran)
	}
	s := panelText(p)
	if !strings.Contains(s, "afk_hs_once") || !strings.Contains(s, "only time the key is shown") {
		t.Fatalf("the new key isn't shown:\n%s", s)
	}
	// It stays up until it is dismissed, whatever else is pressed.
	tap(p, "2", "x", "q")
	if p.tab != TabAPI || p.quit || !strings.Contains(panelText(p), "afk_hs_once") {
		t.Fatal("the key was dismissed by another key")
	}
	tap(p, "enter")
	if strings.Contains(panelText(p), "afk_hs_once") || p.api.secret != nil {
		t.Fatal("the key is still on screen after it was dismissed")
	}
}

func TestAPITabAsksBeforeRiskyActions(t *testing.T) {
	p := panelAt(t, TabAPI)
	src := p.src.(*fakePanel)
	for _, k := range []string{"R", "v", "x"} {
		tap(p, k)
		if p.api.confirm == nil {
			t.Fatalf("%s didn't ask", k)
		}
		tap(p, "esc")
	}
	if len(src.ran) != 0 {
		t.Fatalf("esc still ran %v", src.ran)
	}
	tap(p, "x", "enter", "p")
	if p.api.confirm == nil || !strings.Contains(panelText(p), "may run a CLI on its own sign-in") {
		t.Fatalf("turning sign-ins on didn't ask:\n%s", panelText(p))
	}
	tap(p, "enter", "s")
	want := [][]string{{"api", "rm", "litellm"}, {"config-set", "serve.plan_runs", "on"}, {"api", "serve-start"}}
	if !reflect.DeepEqual(src.ran, want) {
		t.Fatalf("ran %v", src.ran)
	}
}

func TestAPITabEditsAKey(t *testing.T) {
	p := panelAt(t, TabAPI)
	src := p.src.(*fakePanel)
	tap(p, "enter")
	s := panelText(p)
	if !strings.Contains(s, "Requests a minute") || !strings.Contains(s, "answer only (no folder)") || strings.Contains(s, "Models") {
		t.Fatalf("a router key's settings:\n%s", s)
	}
	tap(p, "enter", "ctrl+u", "3", "0", "enter")
	// The mode needs a folder first.
	tap(p, "down", "down", "down", "down", "enter")
	if !strings.Contains(p.notice, "a folder first") {
		t.Fatalf("notice %q", p.notice)
	}
	tap(p, "esc", "down", "enter")
	if s := panelText(p); !strings.Contains(s, "Models") || !strings.Contains(s, "any Grok offers") {
		t.Fatalf("a harness key's settings:\n%s", s)
	}
	// edits -> auto is saved at once; auto -> yolo asks first.
	tap(p, "down", "down", "down", "down", "down", "enter")
	p.data.api.Keys[1].Mode = "auto"
	tap(p, "enter")
	if p.api.confirm == nil || !strings.Contains(panelText(p), "any command in /srv/work") {
		t.Fatalf("yolo didn't ask:\n%s", panelText(p))
	}
	tap(p, "esc")
	want := [][]string{{"api", "set", "litellm", "per-minute", "30"}, {"api", "set", "grok-gw", "mode", "auto"}}
	if !reflect.DeepEqual(src.ran, want) {
		t.Fatalf("ran %v", src.ran)
	}
	// A tab key leaves the settings and changes tab.
	tap(p, "7")
	if p.tab != TabConfig || p.api.edit != "" {
		t.Fatal("7 didn't leave the key's settings")
	}
}
