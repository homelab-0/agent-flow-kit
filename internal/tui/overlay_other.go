//go:build !unix

package tui

// ttyCellSize has no window-size pixels to read here.
func ttyCellSize() (w, h int) { return 0, 0 }
