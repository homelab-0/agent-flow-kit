package tui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/golden"
)

func ptrF(f float64) *float64 { return &f }

func ptrI(i int) *int { return &i }

func frameReceipt(t *testing.T) Receipt {
	ex, _ := fixtureData(t)
	return Receipt{Route: ex.Choice, ExitCode: 0, Duration: 23*time.Minute + 41*time.Second,
		PoolBefore: ptrF(78), PoolAfter: ptrF(71), InRepo: true, Files: ptrI(3), Commits: ptrI(0)}
}

// frameLine is line n (0-based) of a design frame; it skips the test when
// the frames are not available.
func frameLine(t *testing.T, name string, n int) string {
	t.Helper()
	dir := os.Getenv("AFK_DESIGN_FRAMES")
	if dir == "" {
		t.Skip("AFK_DESIGN_FRAMES is not set; the design frames are not in the repository")
	}
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return plainLines(string(b))[n]
}

func TestFrameLaunchLines(t *testing.T) {
	th := NewTheme(true)
	ex, _ := fixtureData(t)
	r := ex.Choice
	if got, want := ansi.Strip(th.LaunchText(r, "here", "r-7f3c", false, 80)), frameLine(t, "06-launch-1-t300ms.txt", 0); strings.TrimRight(got, " ") != want {
		t.Errorf("launch line\n got %q\nwant %q", got, want)
	}
	if got, want := ansi.Strip(th.SessionRuleText(r)), frameLine(t, "06-launch-3-t2900ms.txt", 11); got != want {
		t.Errorf("session rule\n got %q\nwant %q", got, want)
	}
	if got, want := ansi.Strip(th.EndRuleText()), frameLine(t, "08-back-1-t600ms.txt", 3); got != want {
		t.Errorf("end rule\n got %q\nwant %q", got, want)
	}
}

// 08-back-5: the receipt and the rating prompt.
func TestFrameReceiptLines(t *testing.T) {
	th := NewTheme(true)
	got := []string{ansi.Strip(th.ReceiptLine(frameReceipt(t)).render()), ansi.Strip(th.ratingLine().render())}
	want := []string{frameLine(t, "08-back-5-t4500ms.txt", 12), frameLine(t, "08-back-5-t4500ms.txt", 13)}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("receipt\n got %q\nwant %q", got, want)
	}
}

func TestGoldenReceipts(t *testing.T) {
	th := NewTheme(true)
	r := frameReceipt(t)
	var out []string
	out = append(out, ansi.Strip(th.ReceiptLine(r).render()))
	r.Commits = ptrI(2)
	out = append(out, ansi.Strip(th.ReceiptLine(r).render()))
	r.ExitCode, r.InRepo, r.PoolAfter = 1, false, nil
	out = append(out, ansi.Strip(th.ReceiptLine(r).render()))
	r.ExitCode, r.Signal = 137, "SIGKILL"
	out = append(out, ansi.Strip(th.ReceiptLine(r).render()))
	golden.RequireEqual(t, []byte(strings.Join(out, "\n")))
}
