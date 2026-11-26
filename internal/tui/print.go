package tui

import (
	"github.com/charmbracelet/x/ansi"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// Styled strings for the lines afk prints straight to scrollback around
// the session.

// LaunchText is the receipt line printed as the CLI starts.
func (t Theme) LaunchText(r engine.Route, where, id string, yolo bool, width int) string {
	return t.LaunchLine(r, where, id, yolo, width).render()
}

// SessionRuleText is the rule printed just before the CLI takes over.
func (t Theme) SessionRuleText(r engine.Route) string { return t.SessionRule(r).render() }

// EndRuleText is the rule printed when the CLI is done.
func (t Theme) EndRuleText() string { return t.EndRule().render() }

// ReceiptPlain is the receipt line without colour (plain output).
func ReceiptPlain(r Receipt) string {
	return ansi.Strip(NewTheme(true).ReceiptLine(r).render())
}

// RatingPlain is the rating prompt without colour.
func RatingPlain() string { return ansi.Strip(NewTheme(true).ratingLine().render()) }
