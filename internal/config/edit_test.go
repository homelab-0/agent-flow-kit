package config

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	toml "github.com/pelletier/go-toml/v2"
)

func mustSet(t *testing.T, doc, key, lit string) string {
	t.Helper()
	out, err := SetValue([]byte(doc), key, lit)
	if err != nil {
		t.Fatalf("set %s in\n%s\n: %v", key, doc, err)
	}
	return string(out)
}

func decode(t *testing.T, doc string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := toml.Unmarshal([]byte(doc), &m); err != nil {
		t.Fatalf("not valid TOML after the edit: %v\n%s", err, doc)
	}
	return m
}

func lookup(m map[string]any, key string) any {
	var cur any = m
	for _, p := range strings.Split(key, ".") {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[p]
	}
	return cur
}

func TestQuotedKeysStayDistinct(t *testing.T) {
	doc := "version = 1\n\"route.prefer\" = \"x\"\n[route]\nprefer = \"balanced\"\n"
	got := decode(t, mustSet(t, doc, "route.prefer", `"cheap"`))
	if got["route.prefer"] != "x" || lookup(got, "route.prefer") != "cheap" {
		t.Fatalf("%v", got)
	}
	doc = "version = 1\n\"route.prefer\" = \"x\"\n"
	got = decode(t, mustSet(t, doc, "route.prefer", `"best"`))
	if got["route.prefer"] != "x" || lookup(got, "route.prefer") != "best" {
		t.Fatalf("quoted key only: %v", got)
	}
}

func TestMultilineStringRuns(t *testing.T) {
	for _, doc := range []string{
		"version = 1\n[trust]\nrepos = ['''/repo'''', \"/b\"]\n[route]\nprefer = \"best\"\n",
		"version = 1\n[trust]\nrepos = [\"\"\"/repo\"\"\"\"\", \"/b\"]\n[route]\nprefer = \"best\"\n",
		"version = 1\n[trust]\nrepos = [\"\"\"a\\\"\"\"\"]\n[route]\nprefer = \"best\"\n",
		"version = 1\n[trust]\nrepos = [ # a comment with a ] in it\n  '/a', ''\n]\n[route]\nprefer = \"best\"\n",
	} {
		decode(t, doc)
		got := decode(t, mustSet(t, doc, "trust.repos", `["/new"]`))
		if !reflect.DeepEqual(lookup(got, "trust.repos"), []any{"/new"}) || lookup(got, "route.prefer") != "best" {
			t.Fatalf("from\n%s\ngot %v", doc, got)
		}
	}
}

func TestInsertAtEndAfterAComment(t *testing.T) {
	doc := "version = 1\n[route]\nprefer = \"cheap\" # keep"
	got := mustSet(t, doc, "route.prefer_free", "true")
	m := decode(t, got)
	if lookup(m, "route.prefer_free") != true || lookup(m, "route.prefer") != "cheap" || !strings.Contains(got, "# keep\n") {
		t.Fatalf("%q", got)
	}
	got = mustSet(t, "version = 1", "bench.autosync", "false")
	if lookup(decode(t, got), "bench.autosync") != false {
		t.Fatalf("%q", got)
	}
}

func TestTablesDefinedByDottedKeys(t *testing.T) {
	for _, c := range []struct{ doc, key, lit string }{
		{"version = 1\nroute.prefer = \"cheap\"\n", "route.prefer_free", "true"},
		{"version = 1\nroute.prefer = \"cheap\"\n[bench]\nautosync = true\n", "route.allow_metered", "true"},
		{"version = 1\n[gateway]\nwork.url = \"https://w.example\"\n", "gateway.work.key", `"env:W"`},
	} {
		got := mustSet(t, c.doc, c.key, c.lit)
		m := decode(t, got)
		if v := lookup(m, c.key); fmt.Sprint(v) != strings.Trim(c.lit, `"`) {
			t.Fatalf("%s = %v in\n%s", c.key, v, got)
		}
		if strings.Count(got, "[route]") > 0 && strings.Contains(c.doc, "route.prefer") {
			t.Fatalf("a [route] header was added over the dotted keys:\n%s", got)
		}
		if _, err := Parse("config.toml", []byte(got)); err != nil {
			t.Fatalf("%v\n%s", err, got)
		}
	}
}

// Every set leaves the other keys exactly as they were and puts the
// intended value in place, whatever the document looks like.
func TestSetRoundTripProperty(t *testing.T) {
	docs := []string{
		Template,
		"version = 1\n",
		"version = 1 # v\n\n# route\n[route] # r\nprefer = \"balanced\"   # c\nsecurity_models = [ \"a\", # x\n  \"b\" ]\n\n[trust]\nrepos = ['''/x''']\n",
		"version = 1\nroute.prefer = \"best\"\nbench.autosync = true\n",
		"version = 1\n[gateway.work]\nurl = \"https://w.example\"\nkey = \"env:W\"\ndefault = true\n[gateway.home]\nurl = \"http://h.local\"\n",
		"version = 1\n[route]\nprefer = 'cheap'\n[harness.grok]\nenabled = false\n[bench.sources]\nlmarena = { enabled = true }\n",
		"version = 1\n[permissions]\ndefault = \"ask\"\n[permissions.task]\nreview = \"read-only\"\n",
		"version = 1\n[route]\nprefer = \"cheap\"",
	}
	sets := []struct{ key, raw string }{
		{"route.prefer", "best"}, {"route.prefer_free", "true"}, {"route.security_models", "mythos, daybreak-blue"},
		{"trust.repos", "/a,/b"}, {"gateway.work.url", "https://new.example"}, {"gateway.new.key", "env:NEW"},
		{"harness.grok.enabled", "true"}, {"harness.codex.enabled", "false"}, {"bench.autosync", "false"},
		{"bench.weights.coding.swebench", "0.6"}, {"permissions.task.review", "ask"}, {"serve.listen", "tailnet"},
	}
	for di, doc := range docs {
		before := decode(t, doc)
		for _, st := range sets {
			lit, err := EncodeValue(st.key, st.raw)
			if err != nil {
				t.Fatal(err)
			}
			out, err := SetValue([]byte(doc), st.key, lit)
			if err != nil {
				if strings.Contains(err.Error(), "afk config edit") {
					continue // inside an inline table: refused, not mangled
				}
				t.Fatalf("doc %d, %s: %v", di, st.key, err)
			}
			after := decode(t, string(out))
			want := decode(t, st.key+" = "+lit)
			if !reflect.DeepEqual(lookup(after, st.key), lookup(want, st.key)) {
				t.Errorf("doc %d, %s: got %v, want %v\n%s", di, st.key, lookup(after, st.key), lookup(want, st.key), out)
			}
			// Everything else is unchanged.
			stripped := func(m map[string]any) map[string]any {
				b, _ := toml.Marshal(m)
				var c map[string]any
				_ = toml.Unmarshal(b, &c)
				parts := strings.Split(st.key, ".")
				cur := c
				for _, p := range parts[:len(parts)-1] {
					next, ok := cur[p].(map[string]any)
					if !ok {
						return c
					}
					cur = next
				}
				delete(cur, parts[len(parts)-1])
				prune(c)
				return c
			}
			if b, a := stripped(before), stripped(after); !reflect.DeepEqual(b, a) {
				t.Errorf("doc %d, %s changed other keys:\n before %v\n after  %v\n%s", di, st.key, b, a, out)
			}
		}
	}
}

// prune drops tables left empty, so a new empty parent table doesn't count
// as a change.
func prune(m map[string]any) bool {
	for k, v := range m {
		if mm, ok := v.(map[string]any); ok && prune(mm) {
			delete(m, k)
		}
	}
	return len(m) == 0
}

func FuzzSetValue(f *testing.F) {
	f.Add("version = 1\n[route]\nprefer = \"balanced\" # c\n", "route.prefer", "cheap")
	f.Add("version = 1\nroute.prefer = 'x'\n", "route.prefer_free", "true")
	f.Add("version = 1\n[trust]\nrepos = ['''a'''']\n", "trust.repos", "/b")
	f.Fuzz(func(t *testing.T, doc, key, raw string) {
		var m map[string]any
		if toml.Unmarshal([]byte(doc), &m) != nil {
			return
		}
		lit, err := EncodeValue(key, raw)
		if err != nil {
			return
		}
		out, err := SetValue([]byte(doc), key, lit)
		if err != nil {
			return
		}
		var after map[string]any
		if err := toml.Unmarshal(out, &after); err != nil {
			// An edit may produce a document go-toml rejects (a table
			// defined twice); SetKey validates before writing, so that is
			// refused there. It must never panic.
			return
		}
		var want map[string]any
		_ = toml.Unmarshal([]byte(key+" = "+lit), &want)
		if !reflect.DeepEqual(lookup(after, key), lookup(want, key)) {
			t.Fatalf("%q: %s = %v, want %v\n%s", doc, key, lookup(after, key), lookup(want, key), out)
		}
	})
}

func TestVersionZeroIsRefused(t *testing.T) {
	if _, err := Parse("c.toml", []byte("version = 0\n")); err == nil {
		t.Fatal("version = 0 was accepted")
	}
	f, err := Parse("c.toml", []byte("[route]\nprefer = \"cheap\"\n"))
	if err != nil || f.Version != Version || len(f.Warnings) != 1 {
		t.Fatalf("missing version: %+v %v", f, err)
	}
}

func TestConcurrentSetsKeepBothChanges(t *testing.T) {
	f := newEnv(t)
	f.config(t, "version = 1\n")
	p := f.paths()
	keys := []struct{ k, v string }{{"route.prefer", "cheap"}, {"route.prefer_free", "true"}, {"bench.autosync", "false"}, {"serve.listen", "tailnet"}, {"route.allow_metered", "true"}, {"harness.grok.enabled", "false"}}
	var wg sync.WaitGroup
	errs := make([]error, len(keys))
	for i, kv := range keys {
		wg.Add(1)
		go func(i int, k, v string) {
			defer wg.Done()
			_, errs[i] = SetKey(p, k, v, false)
		}(i, kv.k, kv.v)
	}
	wg.Wait()
	b, _ := os.ReadFile(p.Config)
	m := decode(t, string(b))
	for i, kv := range keys {
		if errs[i] != nil {
			t.Fatalf("%s: %v", kv.k, errs[i])
		}
		if fmt.Sprint(lookup(m, kv.k)) != kv.v {
			t.Errorf("%s lost: %v\n%s", kv.k, lookup(m, kv.k), b)
		}
	}
}

func TestApplyRefusesAChangedFile(t *testing.T) {
	f := newEnv(t)
	f.vars["AFK_ROUTER_PREFER_FREE"] = "1"
	f.config(t, "version = 1\n")
	m, err := PlanMigration(f.env())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SetKey(f.paths(), "route.prefer", "best", false); err != nil {
		t.Fatal(err)
	}
	if err := m.Apply(); err == nil || !strings.Contains(err.Error(), "changed meanwhile") {
		t.Fatalf("a stale migration was written: %v", err)
	}
	if b, _ := os.ReadFile(f.paths().Config); !strings.Contains(string(b), `prefer = "best"`) {
		t.Fatalf("the set was lost:\n%s", b)
	}
	// And WriteConfig (afk config edit) the same way.
	if err := WriteConfig(f.paths().Config, []byte("version = 1\n"), []byte("version = 1\n[route]\nprefer = \"cheap\"\n")); err == nil {
		t.Fatal("an edit of an older copy replaced the file")
	}
	if err := WriteConfig(filepath.Join(t.TempDir(), "new.toml"), nil, []byte("version = 1\n")); err != nil {
		t.Fatalf("a new file: %v", err)
	}
}

func TestSetWaitsForMigrateWhileRouterJsonIsInUse(t *testing.T) {
	f := newEnv(t)
	write(t, f.paths().Legacy, `{"litellm_base_url":"http://mine.local"}`)
	if _, err := SetKey(f.paths(), "route.prefer", "cheap", false); err == nil || !strings.Contains(err.Error(), "afk config migrate first") {
		t.Fatalf("set created config.toml over router.json: %v", err)
	}
	if _, err := os.Stat(f.paths().Config); err == nil {
		t.Fatal("config.toml was created")
	}
}

func TestMigrateWritesWhatIsInUse(t *testing.T) {
	f := newEnv(t)
	write(t, f.paths().Legacy, `{"litellm_base_url":"http://old.local:4000","trusted_repos":["/work/a,b","/work/c"]}`)
	f.vars["AFK_LITELLM_BASE_URL"] = "http://env.local:4000"
	f.vars["AFK_GATEWAY_KEY_ENV"] = "TEAM_KEY"
	before := resolve(t, f)
	m, err := PlanMigration(f.env())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(m.Diff, `+url = "http://env.local:4000"`) || strings.Contains(m.Diff, "old.local") || !strings.Contains(m.Diff, `+key = "env:TEAM_KEY"`) {
		t.Fatalf("diff:\n%s", m.Diff)
	}
	if len(m.Skipped) == 0 || !strings.Contains(strings.Join(m.Skipped, "\n"), "AFK_LITELLM_BASE_URL is set") {
		t.Fatalf("the difference isn't reported: %v", m.Skipped)
	}
	if err := m.Apply(); err != nil {
		t.Fatal(err)
	}
	// With the environment gone, config.toml still routes as before.
	delete(f.vars, "AFK_LITELLM_BASE_URL")
	after := resolve(t, f)
	if after.GatewayURL != before.GatewayURL {
		t.Fatalf("gateway %q, was %q", after.GatewayURL, before.GatewayURL)
	}
	file, _ := Load(f.paths().Config)
	if !reflect.DeepEqual(file.Trust.Repos, []string{"/work/a,b", "/work/c"}) {
		t.Fatalf("a path with a comma was split: %v", file.Trust.Repos)
	}
}
