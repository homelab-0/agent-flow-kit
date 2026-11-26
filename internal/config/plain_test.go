package config

import "testing"

func TestProblemsCarryNoEscapeCodes(t *testing.T) {
	p := Problem{File: "/r/.afk/config.json", Key: "ro\x1b]0;owned\x07ute", Msg: "ignored\r\x1b[2K\x1b[1Aafk: all good\u009b31m"}
	want := "/r/.afk/config.json: ro?]0;owned?ute: ignored??[2K?[1Aafk: all good?31m"
	if got := p.String(); got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}
