package serve

import (
	"encoding/json"
)

// Usage is the token count a CLI reported for a run. It is the CLI's own
// figure for everything the run spent, its own system prompt and tool
// steps included, never an estimate.
type Usage struct {
	Input  int
	Output int
}

// decoder reads a CLI's output lines as they are printed: the answer's
// text as it is written, and the usage the CLI reports.
type decoder struct {
	format string
	// wrote is whether any text came out yet; gap is whether the next
	// text starts a new message and needs a blank line before it.
	wrote, gap bool
	usage      *Usage
}

// line reads one output line and returns the answer text it adds ("" for
// none).
func (d *decoder) line(b []byte) string {
	switch d.format {
	case "claude-events":
		return d.claude(b)
	case "codex-items":
		return d.codex(b)
	}
	return ""
}

func (d *decoder) text(s string) string {
	if s == "" {
		return ""
	}
	if d.gap && d.wrote {
		s = "\n\n" + s
	}
	d.gap, d.wrote = false, true
	return s
}

// claude reads Claude Code's stream-json: stream_event lines carry the
// text deltas (with --include-partial-messages), the result line the
// usage.
func (d *decoder) claude(b []byte) string {
	var ev struct {
		Type   string  `json:"type"`
		Parent *string `json:"parent_tool_use_id"`
		Event  struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		} `json:"event"`
		Usage *struct {
			Input       int `json:"input_tokens"`
			CacheCreate int `json:"cache_creation_input_tokens"`
			CacheRead   int `json:"cache_read_input_tokens"`
			Output      int `json:"output_tokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(b, &ev) != nil {
		return ""
	}
	switch ev.Type {
	case "result":
		if u := ev.Usage; u != nil {
			d.usage = &Usage{Input: u.Input + u.CacheCreate + u.CacheRead, Output: u.Output}
		}
	case "stream_event":
		// A subagent's text is not the answer.
		if ev.Parent != nil && *ev.Parent != "" {
			return ""
		}
		switch ev.Event.Type {
		case "message_start":
			d.gap = true
		case "content_block_delta":
			if ev.Event.Delta.Type == "text_delta" {
				return d.text(ev.Event.Delta.Text)
			}
		}
	}
	return ""
}

// codex reads codex exec --json: each finished message is one
// item.completed line, and turn.completed carries the turn's usage.
func (d *decoder) codex(b []byte) string {
	var ev struct {
		Type string `json:"type"`
		Item struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"item"`
		Usage *struct {
			Input  int `json:"input_tokens"`
			Output int `json:"output_tokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(b, &ev) != nil {
		return ""
	}
	switch ev.Type {
	case "turn.completed":
		if u := ev.Usage; u != nil {
			if d.usage == nil {
				d.usage = &Usage{}
			}
			d.usage.Input += u.Input
			d.usage.Output += u.Output
		}
	case "item.completed":
		if ev.Item.Type == "agent_message" {
			d.gap = true
			return d.text(ev.Item.Text)
		}
	}
	return ""
}
