package harness

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Vendor usage lookup.
//
// Some CLIs have no way to print plan usage without a run. Their vendors
// do answer it over HTTPS to the login the CLI saved, which is how the
// CLI's own /usage screen gets it. Reading that login is the one place
// AFK opens a credential file, and it happens only when the person turned
// it on for that harness (harness.<name>.vendor_usage in config.toml, off
// by default): a vendor's terms may not allow another tool to use its
// CLI's login.
//
// The rules every lookup here keeps:
//   - the login is read, used for one GET to the vendor's own host, and
//     dropped: it is never written, logged, cached or put in an error;
//   - AFK never refreshes or rewrites a login. An expired one is left for
//     the CLI to renew;
//   - nothing is sent but the request for the usage figures.

// SourceVendor is Account.UsageSource when the usage came from the
// vendor's usage service, not from the CLI.
const SourceVendor = "vendor"

// VendorReporter is a Reporter that can also ask its vendor's usage
// service, signed in as the CLI.
type VendorReporter interface {
	Reporter
	// Vendor is who is asked ("Anthropic").
	Vendor() string
	// VendorUsage fills rep's usage from the vendor. On any failure it
	// leaves the figures empty and says why in rep.UsageNote.
	VendorUsage(ctx context.Context, e Env, rep *Account)
}

// AskOptions are what the person allowed for one Ask.
type AskOptions struct {
	// VendorUsage lets the harness's module read the CLI's saved login
	// and ask the vendor for usage, when the CLI itself reported none.
	VendorUsage bool
	// NoUsageCommand keeps a module from running its CLI's usage command:
	// an earlier report said the CLI answered it as a prompt
	// (Account.UsageCommandSpent).
	NoUsageCommand bool
}

type noUsageCommandKey struct{}

// usageCommandOff reports whether this Ask may not run a usage command.
func usageCommandOff(ctx context.Context) bool {
	off, _ := ctx.Value(noUsageCommandKey{}).(bool)
	return off
}

// VendorLookup names a harness that has a vendor usage lookup.
type VendorLookup struct {
	Harness, Display, Vendor string
}

// VendorLookups are the harnesses with a vendor usage lookup, by name.
func VendorLookups() []VendorLookup {
	var out []VendorLookup
	for name, r := range reporters {
		vr, ok := r.(VendorReporter)
		if !ok {
			continue
		}
		l := VendorLookup{Harness: name, Display: name, Vendor: vr.Vendor()}
		if a, ok := Lookup(name); ok {
			l.Display = a.Display
		}
		out = append(out, l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Harness < out[j].Harness })
	return out
}

// HasVendorLookup reports whether a harness has a vendor usage lookup.
func HasVendorLookup(name string) bool {
	_, ok := reporters[name].(VendorReporter)
	return ok
}

// vendorLimit is how long one vendor request may take.
const vendorLimit = 6 * time.Second

// vendorHTTP makes the vendor requests. It follows no redirect: the
// login goes to the host named here and nowhere else.
var vendorHTTP = &http.Client{
	Timeout:       vendorLimit,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// errVendorRefused is a vendor saying the login is no good (401, 403).
var errVendorRefused = errors.New("login refused")

// vendorGet is one GET with the CLI's login. The error never carries the
// login or the response body.
func vendorGet(ctx context.Context, url string, header map[string]string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, vendorLimit)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, errors.New("bad address")
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	res, err := vendorHTTP.Do(req)
	if err != nil {
		return nil, errors.New("no answer")
	}
	defer res.Body.Close()
	switch {
	case res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden:
		return nil, errVendorRefused
	case res.StatusCode != http.StatusOK:
		return nil, errors.New("HTTP " + strconv.Itoa(res.StatusCode))
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return nil, errors.New("answer cut short")
	}
	return b, nil
}

// readLogin reads a CLI's saved login file (at most 1 MB).
func readLogin(path string) ([]byte, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 1<<20))
	return b, err == nil && len(b) > 0
}

// vendorNote is why a vendor lookup gave no figure, for the person.
func vendorNote(vendor, cli string, err error) string {
	if errors.Is(err, errVendorRefused) {
		return vendor + " refused " + cli + "'s saved login; open " + cli + " once to renew it"
	}
	return vendor + "'s usage service gave no figure (" + err.Error() + ")"
}

// flexTime reads a time a vendor wrote as RFC 3339 text, or as unix
// seconds or milliseconds (a number, or a number in a string). 0 when it
// is none of those.
func flexTime(raw json.RawMessage) int64 {
	s := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if s == "" || s == "null" {
		return 0
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		if math.IsNaN(f) || math.IsInf(f, 0) || f <= 0 {
			return 0
		}
		// 1e10 separates seconds (before 2286) from milliseconds.
		if f > 1e10 {
			f /= 1000
		}
		return int64(f)
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Unix()
		}
	}
	return 0
}

// pct keeps a percentage inside 0 to 100.
func pct(v float64) float64 { return math.Min(100, math.Max(0, v)) }

// money is an amount to two places ("12.50").
func money(v float64) string { return strconv.FormatFloat(v, 'f', 2, 64) }
