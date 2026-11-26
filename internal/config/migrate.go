package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	udiff "github.com/aymanbagabas/go-udiff"
)

// Template starts a new config.toml.
const Template = `# AFK settings. Every key is described in docs/reference/configuration.md.
version = 1
`

// Change is one key a migration or set writes.
type Change struct {
	Key   string `json:"key"`
	Value string `json:"value"` // as TOML; a secret is only ever a reference
	From  string `json:"from"`  // where it came from
}

// Migration is what afk config migrate would write.
type Migration struct {
	Path    string   `json:"path"`
	Exists  bool     `json:"exists"` // config.toml was already there
	Changes []Change `json:"changes"`
	// Kept are keys config.toml already has, which the old settings would
	// also set; config.toml wins and they are not touched.
	Kept    []string `json:"kept"`
	Skipped []string `json:"skipped"` // settings that can't be migrated, and why
	Diff    string   `json:"diff"`
	before  []byte
	after   []byte
}

// Unchanged reports whether there is nothing to write.
func (m *Migration) Unchanged() bool { return len(m.Changes) == 0 }

// PlanMigration reads the settings AFK used before config.toml (the
// environment and ~/.config/afk/router.json) and works out the config.toml
// that holds them. It reads no secret: a gateway key becomes a reference
// to the variable that holds it. Nothing is written.
func PlanMigration(e Env) (*Migration, error) {
	paths := PathsFor(e.Home, e.Getenv)
	m := &Migration{Path: paths.Config}
	f, err := Load(paths.Config)
	if err != nil {
		return nil, err
	}
	doc := []byte(Template)
	if f.Exists {
		doc, m.Exists = f.Raw, true
	}
	m.before = doc
	have := map[string]bool{}
	if entries, err := scan(doc); err == nil {
		for _, en := range entries {
			have[en.path] = true
		}
	}
	u, _ := readLegacyUser(paths.Legacy)
	legacy := "router.json"

	var changes []Change
	add := func(key, raw, from string) {
		if have[key] {
			m.Kept = append(m.Kept, key)
			return
		}
		lit, err := EncodeValue(key, raw)
		if err != nil {
			m.Skipped = append(m.Skipped, fmt.Sprintf("%s (from %s): %v", key, from, err))
			return
		}
		changes = append(changes, Change{Key: key, Value: lit, From: from})
	}

	gw, gwFrom := u.GatewayURL, legacy+" litellm_base_url"
	if v := e.getenv("AFK_LITELLM_BASE_URL"); v != "" && gw == "" {
		gw, gwFrom = v, "AFK_LITELLM_BASE_URL"
	}
	if gw != "" {
		_, existing := have["gateway"]
		for k := range have {
			if strings.HasPrefix(k, "gateway.") {
				existing = true
			}
		}
		switch pu, err := url.Parse(gw); {
		case existing && !have["gateway.default.url"]:
			m.Skipped = append(m.Skipped, "the gateway from "+gwFrom+": config.toml already defines a gateway")
		case err != nil || pu.Host == "":
			m.Skipped = append(m.Skipped, "the gateway from "+gwFrom+": not a URL")
		case pu.User != nil:
			// A credential in the address: never written to a file.
			m.Skipped = append(m.Skipped, "the gateway from "+gwFrom+": its address carries user info (a credential), which AFK won't write to a file; add [gateway.default] with url and key = \"env:NAME\" yourself")
		default:
			keyVar := e.getenv("AFK_GATEWAY_KEY_ENV")
			keyFrom := "AFK_GATEWAY_KEY_ENV"
			if keyVar == "" {
				keyVar, keyFrom = "AFK_GATEWAY_KEY", "the default key variable"
			}
			add("gateway.default.kind", "litellm", gwFrom)
			add("gateway.default.url", gw, gwFrom)
			add("gateway.default.key", "env:"+keyVar, keyFrom+" (a reference; the key itself is not read)")
			add("gateway.default.default", "true", gwFrom)
		}
	}
	switch {
	case e.getenv("AFK_SECURITY_MODELS") != "":
		add("route.security_models", e.getenv("AFK_SECURITY_MODELS"), "AFK_SECURITY_MODELS")
	case len(u.Security) > 0:
		add("route.security_models", strings.Join(u.Security, ","), legacy+" security_models")
	}
	if len(u.TrustedRepos) > 0 {
		add("trust.repos", strings.Join(u.TrustedRepos, ","), legacy+" trusted_repos")
	}
	for _, b := range []struct{ env, key string }{
		{"AFK_ROUTER_ALLOW_METERED_API", "route.allow_metered"},
		{"AFK_ROUTER_PREFER_FREE", "route.prefer_free"},
		{"AFK_ROUTER_ALLOW_FREE_REVIEWERS", "route.allow_free_reviewers"},
	} {
		if v := e.getenv(b.env); v != "" {
			add(b.key, fmt.Sprint(truthy(v)), b.env)
		}
	}
	if e.getenv("AFK_SKIP_BENCHMARK_AUTOSYNC") == "1" {
		add("bench.autosync", "false", "AFK_SKIP_BENCHMARK_AUTOSYNC")
	}

	after := doc
	for _, c := range changes {
		next, err := SetValue(after, c.Key, c.Value)
		if err != nil {
			m.Skipped = append(m.Skipped, fmt.Sprintf("%s: %v", c.Key, err))
			continue
		}
		after = next
		m.Changes = append(m.Changes, c)
	}
	if _, err := Parse(paths.Config, after); err != nil {
		return nil, fmt.Errorf("the migrated config would not be valid: %w", err)
	}
	m.after = after
	old := string(m.before)
	if !m.Exists {
		old = ""
	}
	if len(m.Changes) > 0 || !m.Exists {
		m.Diff = udiff.Unified(paths.Config+" (now)", paths.Config+" (migrated)", old, string(after))
	}
	return m, nil
}

// Apply writes the migrated config.toml, atomically and under its lock.
// The old files are left as they are.
func (m *Migration) Apply() error {
	if m.Exists && m.Unchanged() {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(m.Path), 0o755); err != nil {
		return err
	}
	return writeLocked(m.Path, m.after)
}

// SetKey sets one key in config.toml: the edited document is validated
// before anything is written, and comments and order are kept. It returns
// the diff; with dryRun nothing is written.
func SetKey(paths Paths, key, raw string, dryRun bool) (string, error) {
	if strings.Contains(key, " ") || key == "" {
		return "", fmt.Errorf("%q is not a key", key)
	}
	if key == "version" {
		return "", fmt.Errorf("version is set by afk")
	}
	lit, err := EncodeValue(key, raw)
	if err != nil {
		return "", err
	}
	if strings.HasSuffix(key, ".key") {
		if _, err := ParseSecretRef(raw); err != nil {
			return "", fmt.Errorf("%s %v", key, err)
		}
	}
	f, err := Load(paths.Config)
	if err != nil {
		return "", err
	}
	doc := []byte(Template)
	old := ""
	if f.Exists {
		doc, old = f.Raw, string(f.Raw)
	}
	after, err := SetValue(doc, key, lit)
	if err != nil {
		return "", err
	}
	if _, err := Parse(paths.Config, after); err != nil {
		return "", err
	}
	diff := udiff.Unified(paths.Config+" (now)", paths.Config+" (new)", old, string(after))
	if dryRun || string(after) == old {
		return diff, nil
	}
	return diff, writeLocked(paths.Config, after)
}

// WriteConfig replaces config.toml with a document that has been
// validated, atomically and under its lock.
func WriteConfig(path string, doc []byte) error {
	if _, err := Parse(path, doc); err != nil {
		return err
	}
	return writeLocked(path, doc)
}
