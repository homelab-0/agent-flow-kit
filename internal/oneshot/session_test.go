package oneshot

import "testing"

func TestSessionID(t *testing.T) {
	cases := []struct{ name, out, want string }{
		{"codex exec --json", `{"type":"thread.started","thread_id":"01a22155-7368-77a3-8bc8-398ad56ba9a7"}` + "\n" + `{"type":"turn.completed"}`, "01a22155-7368-77a3-8bc8-398ad56ba9a7"},
		{"claude stream-json", `{"type":"system","subtype":"init","session_id":"5f0c9c1e-aaaa-bbbb-cccc-000000000001"}` + "\n" + `{"type":"result","result":"ok","session_id":"5f0c9c1e-aaaa-bbbb-cccc-000000000001"}`, "5f0c9c1e-aaaa-bbbb-cccc-000000000001"},
		{"camel case", `{"sessionId":"abc12345","text":"hi"}`, "abc12345"},
		{"none", `{"result":"ok"}`, ""},
		{"not json", "plain answer with session_id: x", ""},
		{"an option is not an id", `{"session_id":"--dangerously-skip-permissions"}`, ""},
		{"a path is not an id", `{"session_id":"../../etc/passwd"}`, ""},
	}
	for _, c := range cases {
		if got := SessionID([]byte(c.out)); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
