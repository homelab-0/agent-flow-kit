package tui

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"strings"
	"sync"

	"charm.land/lipgloss/v2"
)

// Terminals that can't show the logo images get a pixel mark instead: the
// same PNG cut down to two cells of quadrant blocks. Each cell is 2×2
// pixels, so the mark is 4 pixels wide and 2 tall (about square, as a cell
// is twice as tall as it is wide), drawn in the logo's own colours. It is
// plain text, so it works in any terminal with colour, including tmux.

// quadrants are the block characters by which quarters are filled:
// 1 top left, 2 top right, 4 bottom left, 8 bottom right.
var quadrants = [16]string{" ", "▘", "▝", "▀", "▖", "▌", "▞", "▛", "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█"}

// markCell is one cell of a pixel mark. A nil bg is the terminal's own.
type markCell struct {
	ch     string
	fg, bg color.Color
}

var (
	marksOnce sync.Once
	marks     map[string][2]markCell
)

// pixelMarks cuts every embedded logo down to its pixel mark, once.
func pixelMarks() map[string][2]markCell {
	marksOnce.Do(func() {
		marks = map[string][2]markCell{}
		for _, name := range logoNames() {
			b, err := logoFS.ReadFile("logos/" + name + ".png")
			if err != nil {
				continue
			}
			if m, ok := pixelMark(b); ok {
				marks[name] = m
			}
		}
	})
	return marks
}

// pixelMark is a PNG as two quadrant-block cells.
func pixelMark(b []byte) ([2]markCell, bool) {
	img, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		return [2]markCell{}, false
	}
	r := img.Bounds()
	if r.Dx() < 4 || r.Dy() < 2 {
		return [2]markCell{}, false
	}
	// Average each of the 4×2 pixels' areas, weighting colour by alpha.
	var px [2][4]rgba
	for y := range 2 {
		for x := range 4 {
			px[y][x] = average(img, image.Rect(
				r.Min.X+x*r.Dx()/4, r.Min.Y+y*r.Dy()/2,
				r.Min.X+(x+1)*r.Dx()/4, r.Min.Y+(y+1)*r.Dy()/2))
		}
	}
	// Line art too thin to fill three of the eight pixels would come out
	// as specks; those logos keep their text tag.
	var out [2]markCell
	filled := 0
	for c := range 2 {
		q := [4]rgba{px[0][2*c], px[0][2*c+1], px[1][2*c], px[1][2*c+1]}
		out[c] = quadCell(q)
		for _, p := range q {
			if p.a >= markOn {
				filled++
			}
		}
	}
	return out, filled >= 3
}

// markOn is how much of a pixel's area the logo must cover to fill it.
const markOn = 1.0 / 3

// quadCell is the block character and colours closest to four pixels.
// Pixels under a third covered are the terminal's background; when all
// four are covered the two most different colours become fg and bg.
func quadCell(q [4]rgba) markCell {
	mask, n := 0, 0
	var fg rgba
	for i, p := range q {
		if p.a >= markOn {
			mask |= 1 << i
			fg = fg.add(p)
			n++
		}
	}
	switch {
	case n == 0:
		return markCell{ch: " "}
	case n < 4:
		return markCell{ch: quadrants[mask], fg: fg.mean()}
	}
	// Fully covered: split the pixels into two colour groups around the
	// pair that differs most.
	a, b, far := 0, 0, -1.0
	for i := range q {
		for j := i + 1; j < 4; j++ {
			if d := q[i].dist(q[j]); d > far {
				a, b, far = i, j, d
			}
		}
	}
	if far < 0.04 {
		return markCell{ch: quadrants[15], fg: fg.mean()}
	}
	var ga, gb rgba
	mask = 0
	for i, p := range q {
		if p.dist(q[a]) <= p.dist(q[b]) {
			mask |= 1 << i
			ga = ga.add(p)
		} else {
			gb = gb.add(p)
		}
	}
	if ga.n < gb.n { // the larger group is the foreground
		mask, ga, gb = 15^mask, gb, ga
	}
	return markCell{ch: quadrants[mask], fg: ga.mean(), bg: gb.mean()}
}

// rgba is a colour as fractions, accumulated by alpha.
type rgba struct{ r, g, b, a, n float64 }

func average(img image.Image, r image.Rectangle) rgba {
	var s rgba
	var cnt float64
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			c := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
			a := float64(c.A) / 255
			s.r += float64(c.R) / 255 * a
			s.g += float64(c.G) / 255 * a
			s.b += float64(c.B) / 255 * a
			s.a += a
			cnt++
		}
	}
	if s.a > 0 {
		s.r, s.g, s.b = s.r/s.a, s.g/s.a, s.b/s.a
	}
	if cnt > 0 {
		s.a /= cnt
	}
	return s
}

func (s rgba) add(p rgba) rgba {
	return rgba{s.r + p.r, s.g + p.g, s.b + p.b, s.a + p.a, s.n + 1}
}

func (s rgba) mean() color.Color {
	if s.n == 0 {
		return nil
	}
	f := func(v float64) uint8 { return uint8(min(max(v/s.n, 0), 1)*255 + 0.5) }
	return color.RGBA{f(s.r), f(s.g), f(s.b), 255}
}

func (s rgba) dist(p rgba) float64 {
	dr, dg, db := s.r-p.r, s.g-p.g, s.b-p.b
	return dr*dr + dg*dg + db*db
}

// markSeg is a logo's pixel mark as one segment of styled text.
func markSeg(m [2]markCell) seg {
	var b strings.Builder
	for _, c := range m {
		st := lipgloss.NewStyle()
		if c.fg != nil {
			st = st.Foreground(c.fg)
		}
		if c.bg != nil {
			st = st.Background(c.bg)
		}
		b.WriteString(st.Render(c.ch))
	}
	return sg(lipgloss.NewStyle(), b.String())
}
