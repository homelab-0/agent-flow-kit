package tui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// The API tab: AFK's own keys and the server that answers them (afk
// serve). Everything `afk keys` and `afk serve` do is done here: make a
// key, change its limits, give it a folder, rotate, revoke or delete it,
// start and stop the server, and say whether the CLIs' own sign-ins may
// answer.

// APIView is the API tab.
type APIView struct {
	// KeysPath is the file the keys' hashes are kept in.
	KeysPath string
	Server   ServerState
	// PlanRuns is whether the CLIs' own sign-ins may answer served calls;
	// PlanWarning is what is asked before it is turned on.
	PlanRuns    bool
	PlanWarning string
	Keys        []KeyRow
	// Kinds are what a new key can be: the router key first, then one per
	// CLI AFK runs.
	Kinds []KeyKind
}

// ServerState is afk serve as it is now.
type ServerState struct {
	Running bool
	Addr    string // where the running server listens
	PID     int
	Since   time.Time
	// Listen is where the setting says to listen (the next start).
	Listen string
	// Open is whether that address is reachable from other machines.
	Open bool
}

// KeyRow is one key. Nothing here is the key itself: AFK doesn't have it.
type KeyRow struct {
	Name, Hint string // Hint is afk_<id>_…
	Kind       string // router, harness
	Harness    string
	Display    string // the CLI's name as it is written
	Models     []string
	PerMinute  int
	PerDay     int
	Concurrent int
	Dir, Mode  string
	Revoked    bool
	Created    time.Time
	// Runs and LastRun are from the run records of the last 24 hours:
	// calls that reached a CLI.
	Runs    int
	LastRun time.Time
	// Asks is the model name a caller sends.
	Asks string
}

// KeyKind is one thing a new key can be.
type KeyKind struct {
	ID, Label, Desc string
	// Warning, when set, is shown before the key is made.
	Warning []string
}

// APIResult is what an action said. Secret is a new key, shown once.
type APIResult struct {
	Text   string
	Name   string
	Secret string
	Lines  []string // what to do with the key: the model and the address
}

type apiDoneMsg struct {
	panel int
	res   *APIResult
	err   error
}

// apiConfirm is a question a risky action waits on.
type apiConfirm struct {
	lines []string
	yes   string // what enter does
	do    func() tea.Cmd
}

// apiPick is the kind of a new key being chosen.
type apiPick struct {
	name string
	sel  int
}

// apiState is what is open over the API tab.
type apiState struct {
	edit    string // the key whose settings are open
	editSel int
	pick    *apiPick
	confirm *apiConfirm
	secret  *APIResult
}

// apiModal reports whether something on the API tab takes every key.
func (p *Panel) apiModal() bool {
	return p.api.pick != nil || p.api.confirm != nil || p.api.secret != nil
}

func (p *Panel) apiDo(op string, args ...string) tea.Cmd {
	src, ctx, id := p.src, p.ctx, p.id
	if src == nil {
		return nil
	}
	return func() tea.Msg {
		res, err := src.APIDo(ctx, op, args...)
		return apiDoneMsg{panel: id, res: res, err: err}
	}
}

// apiKeyRow is the selected key.
func (p *Panel) apiKeyRow() (KeyRow, bool) {
	v := p.data.api
	i := p.sel[TabAPI]
	if v == nil || i < 0 || i >= len(v.Keys) {
		return KeyRow{}, false
	}
	return v.Keys[i], true
}

// apiEditRow is the key whose settings are open.
func (p *Panel) apiEditRow() (KeyRow, bool) {
	if v := p.data.api; v != nil {
		for _, k := range v.Keys {
			if k.Name == p.api.edit {
				return k, true
			}
		}
	}
	return KeyRow{}, false
}

// apiModalKey takes a key while a question, a choice or a new key is up.
func (p *Panel) apiModalKey(k string) tea.Cmd {
	a := &p.api
	switch {
	case a.secret != nil:
		switch k {
		case "enter", "esc":
			a.secret = nil
		case "c":
			p.notice = "Copied, if your terminal lets a program set the clipboard. Check before you close this."
			return tea.SetClipboard(a.secret.Secret)
		case "ctrl+c":
			p.quit = true
		}
	case a.confirm != nil:
		c := a.confirm
		a.confirm = nil
		if k == "enter" || k == "y" {
			return c.do()
		}
		p.notice = "Nothing changed."
	case a.pick != nil:
		kinds := p.data.api.Kinds
		switch k {
		case "esc":
			a.pick = nil
		case "up", "k":
			a.pick.sel = max(a.pick.sel-1, 0)
		case "down", "j":
			a.pick.sel = min(a.pick.sel+1, max(len(kinds)-1, 0))
		case "enter":
			if a.pick.sel >= len(kinds) {
				a.pick = nil
				return nil
			}
			name, kind := a.pick.name, kinds[a.pick.sel]
			a.pick = nil
			make := func() tea.Cmd { return p.apiDo("add", name, kind.ID) }
			if len(kind.Warning) > 0 {
				a.confirm = &apiConfirm{lines: kind.Warning, yes: "make the key", do: make}
				return nil
			}
			return make()
		}
	}
	return nil
}

// apiKey takes a key on the list of keys.
func (p *Panel) apiKey(k string) tea.Cmd {
	v := p.data.api
	if v == nil {
		return nil
	}
	a := &p.api
	row, has := p.apiKeyRow()
	switch k {
	case "n":
		p.ask = &panelAsk{tab: TabAPI, label: "Name the new key", hint: "What will use it, such as litellm or hindsight. Letters, digits, - and _.",
			done: func(text string) tea.Cmd {
				p.api.pick = &apiPick{name: text}
				return nil
			}}
	case "s":
		if v.Server.Running {
			a.confirm = &apiConfirm{yes: "stop it", do: func() tea.Cmd { return p.apiDo("serve-stop") },
				lines: []string{"Stop afk serve on " + v.Server.Addr + "? Calls it is answering now end, and callers get no answer until it starts again."}}
			return nil
		}
		p.notice = "Starting afk serve…"
		return p.apiDo("serve-start")
	case "p":
		if v.PlanRuns {
			return p.configSave("serve.plan_runs", "off")
		}
		a.confirm = &apiConfirm{lines: []string{v.PlanWarning}, yes: "turn on", do: func() tea.Cmd { return p.configSave("serve.plan_runs", "on") }}
	case "a":
		p.ask = &panelAsk{tab: TabAPI, label: "Listen on", text: v.Server.Listen,
			hint: "host:port. 127.0.0.1:8484 is this machine only; 0.0.0.0:8484 is every network it is on, over plain HTTP. A running server keeps its address until it is stopped and started.",
			done: func(text string) tea.Cmd { return p.configSave("serve.listen", text) }}
	}
	if !has {
		return nil
	}
	switch k {
	case "enter", "right", "l":
		a.edit, a.editSel = row.Name, 0
	case "R":
		a.confirm = &apiConfirm{yes: "rotate", do: func() tea.Cmd { return p.apiDo("rotate", row.Name) },
			lines: []string{"Rotate " + row.Name + "? It gets a new secret and the old one stops working at once, so whatever uses it fails until it has the new one."}}
	case "v":
		if row.Revoked {
			p.notice = row.Name + " is already revoked. R gives it a new secret; x deletes it."
			return nil
		}
		a.confirm = &apiConfirm{yes: "revoke", do: func() tea.Cmd { return p.apiDo("revoke", row.Name) },
			lines: []string{"Revoke " + row.Name + "? It stops working at once. Its record stays, and R brings it back with a new secret."}}
	case "x":
		a.confirm = &apiConfirm{yes: "delete", do: func() tea.Cmd { return p.apiDo("rm", row.Name) },
			lines: []string{"Delete " + row.Name + "? It stops working at once and its record is removed. This can't be undone."}}
	}
	return nil
}

// apiField is one setting of a key, on its settings view.
type apiField struct {
	id, label, value, desc string
	choices                []string // stepped through; nil is typed
	start, hint            string   // the input's first text and what to type
}

var apiModes = []string{"read-only", "edits", "auto", "yolo"}

func limitText(n int) string {
	if n == 0 {
		return "off"
	}
	return fmt.Sprint(n)
}

func (k KeyRow) fields() []apiField {
	num := func(n int) string {
		if n == 0 {
			return "0"
		}
		return fmt.Sprint(n)
	}
	out := []apiField{
		{id: "per-minute", label: "Requests a minute", value: limitText(k.PerMinute), start: num(k.PerMinute), hint: "a count, or 0 for no limit",
			desc: "How many calls are let through in any 60 seconds. One over gets HTTP 429 with Retry-After, so a gateway moves on to its next provider."},
		{id: "per-day", label: "Requests a day", value: limitText(k.PerDay), start: num(k.PerDay), hint: "a count, or 0 for no limit",
			desc: "How many calls are let through in any 24 hours."},
		{id: "concurrent", label: "Runs at once", value: limitText(k.Concurrent), start: num(k.Concurrent), hint: "a count, or 0 for no limit",
			desc: "How many calls may be running at the same moment. Each one is a CLI run on this machine."},
	}
	if k.Kind == "harness" {
		models := "any " + k.Display + " offers"
		if len(k.Models) > 0 {
			models = strings.Join(k.Models, ", ")
		}
		out = append(out, apiField{id: "models", label: "Models", value: models, start: strings.Join(k.Models, ","), hint: "model names separated by commas, or any",
			desc: "The only models a caller may name with this key. any leaves it to what the CLI offers on your plan."})
	}
	dir := "none"
	if k.Dir != "" {
		dir = k.Dir
	}
	mode := k.Mode
	if mode == "" {
		mode = "read-only"
	}
	out = append(out,
		apiField{id: "dir", label: "Folder", value: dir, start: k.Dir, hint: "a folder calls may work in, or none",
			desc: "With none, a call can only answer: it runs read-only in a new empty folder that is deleted afterwards, so it sees and changes none of your files. With a folder, calls run there in the mode below."},
		apiField{id: "mode", label: "May do", value: mode, choices: apiModes,
			desc: "What a call may do in the folder: read-only reads it, edits changes files, auto also runs commands the CLI judges safe, yolo runs anything without asking."})
	return out
}

// apiEditKey takes a key on a key's settings.
func (p *Panel) apiEditKey(k string) tea.Cmd {
	a := &p.api
	row, ok := p.apiEditRow()
	if !ok {
		a.edit = ""
		return nil
	}
	fields := row.fields()
	a.editSel = min(a.editSel, len(fields)-1)
	f := fields[a.editSel]
	step := 0
	switch k {
	case "esc", "backspace":
		a.edit = ""
	case "q", "ctrl+c":
		p.quit = true
	case "up", "k":
		a.editSel = max(a.editSel-1, 0)
	case "down", "j":
		a.editSel = min(a.editSel+1, len(fields)-1)
	case "r":
		return p.load(TabAPI)
	case "enter", "space", "right", "l":
		step = 1
	case "left", "h":
		step = -1
	}
	if step == 0 {
		return nil
	}
	name := row.Name
	if f.choices == nil {
		if step < 0 {
			return nil
		}
		p.ask = &panelAsk{tab: TabAPI, label: f.label, text: f.start, hint: f.hint,
			done: func(text string) tea.Cmd { return p.apiDo("set", name, f.id, text) }}
		return nil
	}
	if row.Dir == "" {
		p.notice = "Give " + name + " a folder first. Without one its calls can only answer."
		return nil
	}
	at := 0
	for i, c := range f.choices {
		if c == f.value {
			at = i
		}
	}
	n := len(f.choices)
	next := f.choices[((at+step)%n+n)%n]
	save := func() tea.Cmd { return p.apiDo("set", name, f.id, next) }
	if next == "yolo" {
		a.confirm = &apiConfirm{yes: "allow it", do: save,
			lines: []string{"With yolo, every call made with " + name + " may run any command in " + row.Dir + " without asking, with your account's permissions. Anyone who holds the key can do that."}}
		return nil
	}
	return save()
}

func (p *Panel) apiLines(w int) ([]line, line) {
	t := p.theme
	v := p.data.api
	a := &p.api
	switch {
	case a.secret != nil:
		return p.apiSecretLines(w), line{sg(t.Key, "c"), sg(t.Dim, " copy  "), sg(t.Key, "↵"), sg(t.Dim, " done  ")}
	case a.confirm != nil:
		var out []line
		for _, s := range a.confirm.lines {
			for _, l := range wrap(s, max(w-4, 20)) {
				out = append(out, line{sg(t.Plain, "  "+l)})
			}
		}
		return out, line{sg(t.Key, "↵"), sg(t.Dim, " "+a.confirm.yes+"  "), sg(t.Key, "esc"), sg(t.Dim, " cancel  ")}
	case a.pick != nil:
		out := []line{{sg(t.Bold, " What may "+a.pick.name+" reach?")}, nil}
		for i, k := range v.Kinds {
			mark, st := sg(t.Plain, " "), t.Plain
			if i == a.pick.sel {
				mark, st = sg(t.Accent, "▌"), t.Bold
			}
			out = append(out, fitLine(line{mark, sg(st, " "+col(k.Label, 22)), sg(t.Dim, k.Desc)}, w))
		}
		return out, line{sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "↵"), sg(t.Dim, " choose  "), sg(t.Key, "esc"), sg(t.Dim, " cancel  ")}
	case a.edit != "":
		if row, ok := p.apiEditRow(); ok {
			return p.apiEditLines(row, w), line{sg(t.Key, "↑↓"), sg(t.Dim, " pick  "), sg(t.Key, "↵"), sg(t.Dim, " change  ")}
		}
		a.edit = ""
	}

	s := v.Server
	var out []line
	if s.Running {
		l := line{sg(t.Dim, " Server    "), sg(t.OK, "● running"), sg(t.Plain, "  http://"+s.Addr)}
		if !s.Since.IsZero() {
			l = append(l, sg(t.Dim, " · up "+ago(p.now().Sub(s.Since))))
		}
		out = append(out, fitLine(l, w))
		if s.Listen != "" && s.Listen != s.Addr {
			out = append(out, fitLine(line{sg(t.Warn, "           The setting is now "+s.Listen+". Stop and start the server to move it there.")}, w))
		}
	} else {
		out = append(out, fitLine(line{sg(t.Dim, " Server    "), sg(t.Dim, "○ stopped"), sg(t.Dim, "  nothing can call AFK until it runs · will listen on "), sg(t.Plain, s.Listen)}, w))
	}
	if s.Open {
		for _, l := range wrap("That address is reachable from other machines, over plain HTTP. Anyone on the network path can read the keys and prompts sent to it; use a private network or put TLS in front.", max(w-13, 20)) {
			out = append(out, line{sg(t.Warn, "           "+l)})
		}
	}
	if v.PlanRuns {
		out = append(out, fitLine(line{sg(t.Dim, " Sign-ins  "), sg(t.OK, "● on"), sg(t.Dim, "       your CLIs' own sign-ins (your subscriptions) may answer calls")}, w))
	} else {
		out = append(out, fitLine(line{sg(t.Dim, " Sign-ins  "), sg(t.Dim, "○ off"), sg(t.Dim, "      only a gateway, a local engine or a free pool answers calls")}, w))
	}
	out = append(out, nil)

	hint := line{sg(t.Key, "n"), sg(t.Dim, " new key  ")}
	if len(v.Keys) == 0 {
		out = append(out, line{sg(t.Dim, " No keys yet. "), sg(t.Key, "n"), sg(t.Dim, " makes one for a gateway or an app to call AFK with.")})
	} else {
		nw := 14
		for _, k := range v.Keys {
			nw = max(nw, min(lenCells(k.Name)+2, 28))
		}
		out = append(out, fitLine(line{sg(t.Dim, "   "+col("KEY", nw)+col("REACHES", 20)+col("A MIN", 7)+col("A DAY", 8)+col("AT ONCE", 9)+col("RUNS 24H", 10)+"MAY DO")}, w))
		for i, k := range v.Keys {
			st := t.Plain
			if k.Revoked {
				st = t.Dim
			}
			row := line{sg(st, "  "+col(k.Name, nw)), sg(st, col(k.reaches(), 20)),
				sg(st, col(limitText(k.PerMinute), 7)), sg(st, col(limitText(k.PerDay), 8)), sg(st, col(limitText(k.Concurrent), 9)),
				sg(st, col(fmt.Sprint(k.Runs), 10))}
			if k.Revoked {
				row = append(row, sg(t.Warn, "revoked"))
			} else {
				row = append(row, sg(st, k.mayDo()))
			}
			out = append(out, p.selRow(fitLine(row, w-1), i, w))
		}
		if k, ok := p.apiKeyRow(); ok {
			out = append(out, nil)
			out = append(out, p.apiDetail(k, w)...)
		}
		hint = append(hint, sg(t.Key, "↵"), sg(t.Dim, " settings  "), sg(t.Key, "R"), sg(t.Dim, " rotate  "), sg(t.Key, "v"), sg(t.Dim, " revoke  "), sg(t.Key, "x"), sg(t.Dim, " delete  "))
	}
	if s.Running {
		hint = append(hint, sg(t.Key, "s"), sg(t.Dim, " stop  "))
	} else {
		hint = append(hint, sg(t.Key, "s"), sg(t.Dim, " start  "))
	}
	hint = append(hint, sg(t.Key, "p"), sg(t.Dim, " sign-ins  "), sg(t.Key, "a"), sg(t.Dim, " address  "))
	return out, hint
}

func (k KeyRow) reaches() string {
	if k.Kind == "harness" {
		if k.Display != "" {
			return k.Display + " only"
		}
		return k.Harness + " only"
	}
	return "AFK picks"
}

func (k KeyRow) mayDo() string {
	if k.Dir == "" {
		return "answer only"
	}
	mode := k.Mode
	if mode == "" {
		mode = "read-only"
	}
	return mode + " in " + k.Dir
}

// apiDetail is what the selected key is and how a caller uses it.
func (p *Panel) apiDetail(k KeyRow, w int) []line {
	t := p.theme
	v := p.data.api
	head := line{sg(t.Bold, "  "+k.Name), sg(t.Dim, " · "+k.Hint)}
	if !k.Created.IsZero() {
		head = append(head, sg(t.Dim, " · made "+k.Created.Local().Format("2006-01-02")))
	}
	out := []line{fitLine(head, w)}
	row := func(label, text string) {
		for i, l := range wrap(text, max(w-16, 20)) {
			if i > 0 {
				label = ""
			}
			out = append(out, line{sg(t.Dim, "  "+col(label, 12)), sg(t.Plain, l)})
		}
	}
	addr := v.Server.Addr
	if !v.Server.Running {
		addr = v.Server.Listen
	}
	row("Address", "http://"+addr+"/v1")
	row("Model", k.Asks)
	if k.Kind == "harness" && len(k.Models) > 0 {
		row("Models", strings.Join(k.Models, ", "))
	}
	if !k.LastRun.IsZero() {
		row("Last run", ago(p.now().Sub(k.LastRun))+" ago")
	}
	switch {
	case k.Revoked:
		out = append(out, line{sg(t.Warn, "  Revoked: it no longer works. R gives it a new secret.")})
	case k.Kind == "harness" && !v.PlanRuns:
		out = append(out, line{sg(t.Warn, "  It won't answer yet: sign-ins are off. p turns them on.")})
	}
	return out
}

func (p *Panel) apiEditLines(k KeyRow, w int) []line {
	t := p.theme
	fields := k.fields()
	sel := min(p.api.editSel, len(fields)-1)
	out := []line{{sg(t.Bold, " "+k.Name), sg(t.Dim, " · "+k.reaches()+" · "+k.Hint)}, nil}
	for i, f := range fields {
		mark, st := sg(t.Plain, " "), t.Plain
		if i == sel {
			mark, st = sg(t.Accent, "▌"), t.Bold
		}
		val := line{sg(t.Plain, "  "+f.value)}
		if f.choices != nil && k.Dir == "" {
			val = line{sg(t.Dim, "  answer only (no folder)")}
		} else if f.choices != nil && i == sel {
			val = line{sg(t.Accent, "‹ "), sg(t.Plain, f.value), sg(t.Accent, " ›")}
		}
		out = append(out, fitLine(append(line{mark, sg(st, " "+col(f.label, 22))}, val...), w))
	}
	out = append(out, nil)
	for _, l := range wrap(fields[sel].desc, max(w-4, 20)) {
		out = append(out, line{sg(t.Dim, "  "+l)})
	}
	return out
}

func (p *Panel) apiSecretLines(w int) []line {
	t := p.theme
	r := p.api.secret
	out := []line{{sg(t.Bold, " "+r.Text)}, nil,
		{sg(t.Plain, " This is the only time the key is shown. AFK keeps a hash of it, not the key.")}, nil,
		{sg(t.Accent.Bold(true), "   "+r.Secret)}, nil}
	for _, s := range r.Lines {
		for _, l := range wrap(s, max(w-4, 20)) {
			out = append(out, line{sg(t.Dim, "  "+l)})
		}
	}
	return out
}
