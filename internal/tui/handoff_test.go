package tui

import (
	"strings"
	"testing"
	"time"
)

func frameLines(t *testing.T, name string, from, to int) []string {
	t.Helper()
	var out []string
	for i := from; i < to; i++ {
		out = append(out, frameLine(t, name, i))
	}
	return out
}

func sameLines(t *testing.T, what string, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("%s\n--- got\n%s\n--- frame\n%s", what, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestFrameHandoff(t *testing.T) {
	r := fixtures(t).ex.Choice
	got := plainLines(NewTheme(true).HandoffText(r, true, 80))
	sameLines(t, "handoff", got, frameLines(t, "06-launch-3-t2900ms.txt", 2, 10))
}

func TestHandoffWithoutArt(t *testing.T) {
	r := fixtures(t).ex.Choice
	for _, w := range []int{80, 60} {
		art := w == 60
		if got := plainLines(NewTheme(true).HandoffText(r, art, w)); len(got) != 1 || got[0] != "  Esc is afk.  claude has the terminal." {
			t.Errorf("art %v width %d: %q", art, w, got)
		}
	}
}

// backModel is the receipt with Esc walking back in, at a clock the test sets.
func backModel(t *testing.T, at *time.Duration) *RatingModel {
	t.Helper()
	m := NewRating(frameReceipt(t), nil, func(string) error { return nil }, true, true).
		WithEsc(true, 80, func() time.Time { return frameNow.Add(*at) })
	m.Init()
	return m
}

func TestFrameEscComesBack(t *testing.T) {
	var at time.Duration
	m := backModel(t, &at)
	at = 1500 * time.Millisecond
	got := plainLines(m.Render())
	sameLines(t, "walking back", got, frameLines(t, "08-back-2-t1500ms.txt", 5, 13))
	m.Update(key("1"))
	if m.done {
		t.Fatal("a key while Esc walks only brings it home; it must not rate")
	}
	at = 4500 * time.Millisecond
	m.Update(key("1"))
	got = plainLines(m.Render())
	sameLines(t, "home with the receipt", got, frameLines(t, "08-back-5-t4500ms.txt", 5, 15))
}

func TestFrameEscHappyInHammock(t *testing.T) {
	var at time.Duration
	m := backModel(t, &at)
	at = 2600 * time.Millisecond
	got := plainLines(m.Render())
	sameLines(t, "happy in the hammock", got[:6], frameLines(t, "08-back-3-t2600ms.txt", 5, 11))
}
