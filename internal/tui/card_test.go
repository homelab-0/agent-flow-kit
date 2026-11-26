package tui

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/golden"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// fixtureData is the explain and pools fixtures the golden frames use.
func fixtureData(t *testing.T) (*engine.Explain, *engine.Pools) {
	t.Helper()
	b, err := os.ReadFile("testdata/explain.json")
	if err != nil {
		t.Fatal(err)
	}
	ex, err := engine.ParseExplain(b)
	if err != nil {
		t.Fatal(err)
	}
	pb, err := os.ReadFile("testdata/pools.json")
	if err != nil {
		t.Fatal(err)
	}
	p, err := engine.ParsePools(pb)
	if err != nil {
		t.Fatal(err)
	}
	return ex, p
}

var frameNow = time.Date(2026, 11, 25, 22, 0, 0, 0, time.UTC)

const framePrompt = "fix the flaky renovate test in factory-router-tests"

// cardFor is the settled card on the fixtures with row sel selected (-1:
// the router's choice).
func cardFor(t *testing.T, ex *engine.Explain, pools *engine.Pools, sel int) Card {
	t.Helper()
	rows, choice := ex.Rows()
	if sel < 0 {
		sel = choice
	}
	return Card{Prompt: framePrompt, Task: ex.Task, Guessed: ex.TaskGuessed, Prefer: ex.Prefer, Rows: rows, Sel: sel,
		Efforts: map[int]string{}, Prog: 1, Pools: pools, Now: frameNow, Loc: time.UTC}
}

// renderCard draws the card as the program does at that width.
func renderCard(c Card, width int) string {
	t := NewTheme(true)
	if width > 0 && width < compactBelow {
		return join(t.CompactLines(c, width, true))
	}
	return join(t.CardLines(c, width, true))
}

func fixtureCard(t *testing.T, sel int) Card {
	ex, p := fixtureData(t)
	return cardFor(t, ex, p, sel)
}

func plainLines(s string) []string {
	ls := strings.Split(ansi.Strip(s), "\n")
	for i := range ls {
		ls[i] = strings.TrimRight(ls[i], " ")
	}
	return ls
}

// --- design frames ------------------------------------------------------
//
// With AFK_DESIGN_FRAMES set to the design's frames/ folder, the card is
// compared with the golden frames line by line. What is normalised:
//   - the header card above the "›" line (mascot and composer: a later step);
//   - the two reason lines in the box: the frames hold hand-written prose,
//     the card writes the reason from the router's fields;
//   - gateway rows and the gateway box: the frames show a gateway name and
//     the engine behind it (agentgateway, vLLM), which today's engine does
//     not report, so the card shows "gateway" and the gateway host;
//   - the ollama row: today's engine has no local-engine route.

var gwRow = regexp.MustCompile(`^(.)  GW .*$`)

func normalise(ls []string, boxMask map[int]bool) []string {
	var out []string
	for _, l := range ls {
		if strings.HasPrefix(l, "   OL ") || strings.HasPrefix(l, "▌  OL ") {
			continue
		}
		out = append(out, l)
	}
	for i, l := range out {
		if boxMask[i] && strings.HasPrefix(l, "│") {
			out[i] = "│<masked>│"
		}
		out[i] = gwRow.ReplaceAllString(out[i], "$1  GW <gateway row>")
	}
	return out
}

func frame(t *testing.T, name string) []string {
	t.Helper()
	dir := os.Getenv("AFK_DESIGN_FRAMES")
	if dir == "" {
		t.Skip("AFK_DESIGN_FRAMES is not set; the design frames are not in the repository")
	}
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	ls := plainLines(string(b))
	for i, l := range ls {
		if strings.HasPrefix(l, "› ") {
			ls = ls[i:]
			break
		}
	}
	for len(ls) > 0 && ls[len(ls)-1] == "" {
		ls = ls[:len(ls)-1]
	}
	return ls
}

func compareFrame(t *testing.T, name, got string, boxMask map[int]bool) {
	t.Helper()
	want := normalise(frame(t, name), boxMask)
	have := normalise(plainLines(got), boxMask)
	if strings.Join(want, "\n") != strings.Join(have, "\n") {
		t.Errorf("%s differs\n--- frame\n%s\n--- card\n%s", name, strings.Join(want, "\n"), strings.Join(have, "\n"))
	}
}

var reasonLines = map[int]bool{5: true, 6: true}

func gatewayBox() map[int]bool { return map[int]bool{2: true, 3: true, 5: true, 6: true, 8: true} }

func TestFrameCardSettled(t *testing.T) {
	compareFrame(t, "04-card-2-t1600ms.txt", renderCard(fixtureCard(t, -1), 80), reasonLines)
}

func TestFramePick(t *testing.T) {
	compareFrame(t, "05-pick-1-t350ms.txt", renderCard(fixtureCard(t, 2), 80), reasonLines)
	compareFrame(t, "05-pick-2-t650ms.txt", renderCard(fixtureCard(t, 3), 80), gatewayBox())
	// 05-pick-3 selects the ollama row, which has no counterpart yet.
	compareFrame(t, "05-pick-4-t1300ms.txt", renderCard(fixtureCard(t, 0), 80), reasonLines)
}

// --- snapshots kept in the repository -----------------------------------

func TestGoldenCard(t *testing.T) {
	golden.RequireEqual(t, []byte(strings.Join(plainLines(renderCard(fixtureCard(t, -1), 80)), "\n")))
}

func TestGoldenCardPickedGateway(t *testing.T) {
	golden.RequireEqual(t, []byte(strings.Join(plainLines(renderCard(fixtureCard(t, 3), 80)), "\n")))
}

func TestGoldenCompact(t *testing.T) {
	golden.RequireEqual(t, []byte(strings.Join(plainLines(renderCard(fixtureCard(t, -1), 60)), "\n")))
}

func TestGoldenWhy(t *testing.T) {
	golden.RequireEqual(t, []byte(strings.Join(plainLines(join(NewTheme(true).WhyLines(fixtureCard(t, -1), 80))), "\n")))
}

func TestUnknownValuesAreNotZero(t *testing.T) {
	ex, p := fixtureData(t)
	r := ex.ByHarness[1]
	r.PoolHeadroomPct, r.EffectiveScore = nil, nil
	ex.ByHarness[1] = r
	out := ansi.Strip(renderCard(cardFor(t, ex, p, 1), 80))
	if !strings.Contains(out, "[??????????] n/e") || !strings.Contains(out, "codex        gpt-6.1-sol      high   n/e") {
		t.Errorf("unknown headroom and score render as unknown:\n%s", out)
	}
	if strings.Contains(out, " 0%") {
		t.Errorf("no fake zero:\n%s", out)
	}
}

func TestGatewayHostHidesUserInfo(t *testing.T) {
	out := ansi.Strip(renderCard(fixtureCard(t, 3), 80))
	if strings.Contains(out, "user") || strings.Contains(out, "pw@") || !strings.Contains(out, "the gateway at factory") {
		t.Errorf("only the gateway host is shown:\n%s", out)
	}
}

func TestErrorDialogs(t *testing.T) {
	th := NewTheme(true)
	out := ansi.Strip(join(th.ErrorLines(fixtureCard(t, 1), 80, "Codex is not signed in on this machine.", 0)))
	for _, want := range []string{"Can't launch codex / gpt-6.1-sol", "Codex is not signed in on this machine.", "use next best (claude / claude-fable-5-2)", "never copies or forwards a plan login"} {
		if !strings.Contains(out, want) {
			t.Errorf("launch error lacks %q:\n%s", want, out)
		}
	}
}

func TestWidths(t *testing.T) {
	th := NewTheme(true)
	for _, w := range []int{80, 76, 72, 70, 69, 50, 40} {
		c := fixtureCard(t, -1)
		for _, out := range []string{renderCard(c, w), join(th.WhyLines(c, w)), join(th.ErrorLines(c, w, "a long reason that has to wrap inside the box at every width we draw", 1))} {
			for _, l := range plainLines(out) {
				if n := ansi.StringWidth(l); n > w {
					t.Errorf("width %d: line of %d cells: %q", w, n, l)
				}
			}
		}
	}
}

// The Why panel of the chosen route says when its pool figure is an
// estimate from recent sessions.
func TestWhyPanelShowsAnEstimatedPool(t *testing.T) {
	c := fixtureCard(t, -1)
	r := c.Rows[c.Sel]
	r.PoolQuotaSource = "local_5h_activity"
	r.Raw = nil
	c.Rows[c.Sel] = r
	out := strings.Join(plainLines(join(NewTheme(true).WhyLines(c, 120))), "\n")
	if !strings.Contains(out, "of 5h window left") || !strings.Contains(out, "pool figure    estimated") {
		t.Fatalf("no estimate in the Why panel:\n%s", out)
	}
	r.PoolQuotaSource = "codex_rate_limits"
	c.Rows[c.Sel] = r
	if out := strings.Join(plainLines(join(NewTheme(true).WhyLines(c, 120))), "\n"); !strings.Contains(out, "pool figure    measured") {
		t.Fatalf("no basis for a measured pool:\n%s", out)
	}
}

// A newer pools reading moves the figure, its window and its reset
// together, never one without the others.
func TestPoolFigureComesFromOneReading(t *testing.T) {
	c := fixtureCard(t, -1)
	r := c.Rows[c.Sel]
	ninety, sixty, forty := 90.0, 60.0, 40.0
	r.PoolHeadroomPct = &ninety
	c.Pools = &engine.Pools{Pools: map[string]engine.Pool{
		r.EntitlementPool: {HeadroomPct: &sixty, WeeklyUsedPct: &forty, UsageWindow: "weekly"},
	}}
	head, win, _ := c.poolFigure(r)
	if head == nil || *head != 60 || win != "weekly window" {
		t.Fatalf("got %v %q, want the snapshot's 60%% of the weekly window", head, win)
	}
	c.Pools = nil
	if head, win, resets := c.poolFigure(r); head == nil || *head != 90 || win != "5h window" || resets != "resets "+unknownText {
		t.Fatalf("no snapshot: %v %q %q", head, win, resets)
	}
}

// The Why panel says where the route's plan window is heading and what
// pacing did to the score, or that it was off.
func TestWhyPanelShowsPacing(t *testing.T) {
	c := fixtureCard(t, -1)
	c.Now = time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	c.Loc = time.UTC
	r := c.Rows[c.Sel]
	unused := 58.0
	r.Pacing = &engine.Pacing{Window: "weekly", ResetsAt: "2026-11-26T21:00:00Z", ElapsedPct: 95, UnusedAtResetPct: &unused, Adjustment: 3.8}
	c.Rows[c.Sel] = r
	why := func() string { return strings.Join(plainLines(join(NewTheme(true).WhyLines(c, 80))), "\n") }
	if out := why(); !strings.Contains(out, "not applied (route.pacing is off)") || !strings.Contains(out, "weekly window resets in 9h with ~58% unused") {
		t.Fatalf("pacing off:\n%s", out)
	}
	adj := 3.8
	r.PacingAdjustment = &adj
	c.Rows[c.Sel] = r
	if out := why(); !strings.Contains(out, "pacing         +3.8 to the score") {
		t.Fatalf("pacing on:\n%s", out)
	}
	short := "2026-11-26T19:00:00Z"
	r.Pacing = &engine.Pacing{Window: "weekly", ResetsAt: "2026-12-01T16:00:00Z", ElapsedPct: 30, RunsOutAt: &short, Adjustment: -4}
	c.Rows[c.Sel] = r
	if out := why(); !strings.Contains(out, "weekly window runs out 19:00, resets in 5d 4h") {
		t.Fatalf("running out:\n%s", out)
	}
	r.Pacing, r.PacingAdjustment = nil, nil
	c.Rows[c.Sel] = r
	if out := why(); strings.Contains(out, "pacing") {
		t.Fatalf("pacing row with no projection:\n%s", out)
	}
}
