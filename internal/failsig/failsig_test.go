package failsig

import "testing"

func TestAuth(t *testing.T) {
	for text, want := range map[string]bool{
		"401":                                 true,
		"401 Unauthorized":                    true,
		"HTTP 401":                            true,
		"error: status=401":                   true,
		"API Error: 401 {\"type\":\"error\"}": true,
		"Error: not logged in":                true,
		"Please login again":                  true,
		"authentication_failed":               true,
		"refresh token was revoked":           true,
		"  at main.go line 1401":              false,
		"panic at handler.go:401":             false,
		"read 401 bytes":                      false,
		"processed 401 files":                 false,
		"stream disconnected":                 false,
	} {
		if got := Auth(text); got != want {
			t.Errorf("Auth(%q) = %v, want %v", text, got, want)
		}
	}
}

func TestQuota(t *testing.T) {
	for text, want := range map[string]bool{
		"429":                            true,
		"429 Too Many Requests":          true,
		"HTTP 429":                       true,
		"rate_limit_error":               true,
		"rate limited, retry in 30s":     true,
		"quota exceeded":                 true,
		"Claude AI usage limit reached":  true,
		"Your credit balance is too low": true,
		"traceback: line 429, in run":    false,
		"QuotaManager.java:12":           false,
		"took 1429 ms":                   false,
		"stream disconnected":            false,
	} {
		if got := Quota(text); got != want {
			t.Errorf("Quota(%q) = %v, want %v", text, got, want)
		}
	}
}

func TestOverloaded(t *testing.T) {
	for text, want := range map[string]bool{
		"API Error: 529 overloaded": true,
		"529":                       true,
		"overloaded_error":          true,
		"line 529":                  false,
	} {
		if got := Overloaded(text); got != want {
			t.Errorf("Overloaded(%q) = %v, want %v", text, got, want)
		}
	}
	if Quota("529 overloaded") {
		t.Error("an overloaded provider is not a spent quota")
	}
}

func TestNeedsQuotaPrefix(t *testing.T) {
	for text, want := range map[string]bool{
		"Claude AI usage limit reached": true,
		"529 overloaded":                false,
		"429 rate limit":                false,
		"quota exceeded":                false,
	} {
		if got := NeedsQuotaPrefix(text); got != want {
			t.Errorf("NeedsQuotaPrefix(%q) = %v, want %v", text, got, want)
		}
	}
}
