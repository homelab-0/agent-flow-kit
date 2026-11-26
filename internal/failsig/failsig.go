// Package failsig recognises the failures that say something about a plan
// pool: a sign-in failure, a spent quota or rate limit, or an overloaded
// provider. It matches only words and status codes that stand on their
// own, so a line number such as "line 1401", or a word such as
// "QuotaManager", doesn't read as a failure. Callers pass error text only
// (stderr, an error document, a launch error), never the model's answer.
package failsig

import (
	"regexp"
	"strings"
)

// status is an HTTP status code in a context that says it is one: on its
// own, after "http", "status", "code", "error" or "api" (with up to a
// few separator characters between), or followed by its reason phrase.
func status(codes, phrase string) *regexp.Regexp {
	return regexp.MustCompile(`(^\s*(` + codes + `)\s*$` +
		`|\b(http|status|code|error|api)\b[\s:=/"'#-]{0,12}\b(` + codes + `)\b` +
		`|\b(` + codes + `)\b[\s:-]{0,3}(` + phrase + `))`)
}

var (
	authStatus  = status(`401`, `unauthori[sz]ed`)
	quotaStatus = status(`429`, `too\s+many|rate`)
	overStatus  = status(`529`, `overloaded`)

	authWords  = regexp.MustCompile(`\b(unauthori[sz]ed|token_revoked|invalidated\s+oauth|refresh\s+token|not\s+logged\s+in|please\s+log\s?in|please\s+run\s+/login|authentication_failed|invalid\s+api\s+key)\b`)
	quotaWords = regexp.MustCompile(`\b(rate_limit\w*|rate[\s-]limit(ed)?|quota|out_of_credits|spend_limit|exhausted|usage\s+limit|credit\s+balance)\b`)
	overWords  = regexp.MustCompile(`\b(overloaded(_error)?)\b`)
	// CLI wording for a spent plan that the signals reader would not
	// otherwise take as a quota failure.
	quotaPhrase = regexp.MustCompile(`\b(usage\s+limit|credit\s+balance)\b`)
	quotaStrong = regexp.MustCompile(`\b(rate_limit\w*|rate[\s-]limit(ed)?|quota)\b`)
)

// Auth reports a sign-in failure.
func Auth(text string) bool {
	t := strings.ToLower(text)
	return authWords.MatchString(t) || authStatus.MatchString(t)
}

// Quota reports a spent quota or a rate limit.
func Quota(text string) bool {
	t := strings.ToLower(text)
	return quotaWords.MatchString(t) || quotaStatus.MatchString(t)
}

// Overloaded reports a provider that is overloaded (529): a reason to try
// another route, not a sign that this plan is spent.
func Overloaded(text string) bool {
	t := strings.ToLower(text)
	return overWords.MatchString(t) || overStatus.MatchString(t)
}

// Pool reports any failure that says something about the route's pool.
func Pool(text string) bool { return Auth(text) || Quota(text) || Overloaded(text) }

// NeedsQuotaPrefix reports wording that is a quota event but that the
// signals reader would class as transient without a "quota: " prefix.
func NeedsQuotaPrefix(text string) bool {
	t := strings.ToLower(text)
	return quotaPhrase.MatchString(t) && !quotaStrong.MatchString(t) && !quotaStatus.MatchString(t)
}
