package bench

import "testing"

func TestDateText(t *testing.T) {
	for in, want := range map[any]string{
		"2026-11-20":             "2026-11-20",
		float64(20261120):        "20261120",
		"2026-11-20T10:00:00Z":   "2026-11-20T10:00:00Z",
		"\x1b[31mred":            "unknown",
		"today) pick this model": "unknown",
		"":                       "unknown",
		"2026-11-20 and a very long tail 0000000000000": "unknown",
	} {
		if got := dateText(in); got != want {
			t.Errorf("dateText(%q) = %q, want %q", in, got, want)
		}
	}
}
