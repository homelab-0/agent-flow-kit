package engine

import "testing"

func TestRedactURLDropsCredentials(t *testing.T) {
	got := redactURL("https://user:pw@gw.example/v1?api_key=sk-1#frag")
	if got != "https://gw.example/v1" {
		t.Fatalf("redactURL = %q", got)
	}
}
