package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/exp/teatest/v2"
)

// 08-back-5: the receipt, the rating prompt and the saved line. The frame's
// "Esc flopped back into the hammock." is the mascot (a later step), so the
// last line is compared up to "Saved.".
func TestFrameReceipt(t *testing.T) {
	m := NewRating(frameReceipt(t), nil, func(string) error { return nil }, true, false)
	m.Init()
	m.Update(key("1"))
	got := plainLines(m.Render())
	want := []string{frameLine(t, "08-back-5-t4500ms.txt", 12), frameLine(t, "08-back-5-t4500ms.txt", 13), "    Saved."}
	if !strings.HasPrefix(frameLine(t, "08-back-5-t4500ms.txt", 14), want[2]) {
		t.Fatalf("frame line 14 is %q", frameLine(t, "08-back-5-t4500ms.txt", 14))
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("receipt\n got %q\nwant %q", got, want)
	}
	if m.Outcome != "solved" {
		t.Errorf("1 is solved, got %q", m.Outcome)
	}
}

func TestRatingKeys(t *testing.T) {
	for k, want := range map[string]string{"1": "solved", "2": "partly", "3": "wrong-pick", "enter": "", "esc": ""} {
		var saved []string
		m := NewRating(frameReceipt(t), nil, func(o string) error { saved = append(saved, o); return nil }, true, false)
		m.Update(key("x")) // ignored
		m.Update(key(k))
		if m.Outcome != want || !m.done || len(saved) != 1 || saved[0] != want {
			t.Errorf("%s: outcome %q done %v saved %v", k, m.Outcome, m.done, saved)
		}
	}
}

func TestRatingWaitsForFill(t *testing.T) {
	var saved []string
	m := NewRating(Receipt{Route: fixtures(t).ex.Choice, Duration: time.Second}, func() Receipt { return frameReceipt(t) },
		func(o string) error { saved = append(saved, o); return nil }, true, false)
	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(80, 20))
	teatest.WaitFor(t, tm.Output(), func(b []byte) bool { return strings.Contains(string(b), "How did it go?") },
		teatest.WithDuration(5*time.Second))
	tm.Send(key("2"))
	fm := tm.FinalModel(t, teatest.WithFinalTimeout(5*time.Second)).(*RatingModel)
	if fm.Outcome != "partly" || len(saved) != 2 || saved[0] != "" || saved[1] != "partly" {
		t.Fatalf("the run is saved once the receipt is known, then with the rating: %q %v", fm.Outcome, saved)
	}
}
