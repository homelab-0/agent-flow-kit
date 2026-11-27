package tui

import (
	"charm.land/lipgloss/v2"
)

// Esc is the AFK mascot: a lazy mint keycap with legs that lives in a
// striped hammock. It is pixel art on a grid where each terminal cell
// holds two vertical pixels: ▀ with the top pixel as foreground and the
// bottom one as background, ▄ when only the bottom is set, █ when both
// match. The scene is 12 px (6 cells) tall.

const escRows = 12 // pixel rows of every scene

// Pixel keys and their colours. The mascot keeps its own colours on light
// and dark terminals alike.
var escPalette = map[byte]string{
	'T': "#63dcbb", // keycap top face
	'S': "#2a9a80", // rim, sides and eyelids
	'E': "#0c1016", // eyes and mouth
	'L': "#8a93a3", // legs
	'H': "#e07a5f", // hammock stripe A
	'h': "#f2e6cc", // hammock stripe B
	'R': "#c8b27f", // ropes
	'P': "#7b5b3e", // posts
}

// Eyes are the two eye rows; the middle ten pixels are used.
var escEyes = map[string][2]string{
	"lidded": {".TTSTTTTSTT.", ".TTETTTTETT."},
	"left":   {".TSTTTTSTTT.", ".TETTTTETTT."},
	"right":  {".TTTSTTTTST.", ".TTTETTTTET."},
	"closed": {".TTTTTTTTTT.", ".TTEETTEETT."},
	"happy":  {".TTETTTTETT.", ".TETETTETET."},
	"wide":   {".TTETTTTETT.", ".TTETTTTETT."},
}

var escLegs = map[string][2]string{
	"stand": {"..L......L..", "..L......L.."},
	"a":     {"..L......L..", ".L......L..."},
	"b":     {"..L......L..", "...L......L."},
}

// Pose is how Esc looks in one frame.
type Pose struct {
	Stand bool   // standing in front of the empty hammock (else lying in it)
	X     int    // standing: left pixel column of Esc
	Eyes  string // lidded, left, right, closed, happy, wide (in the hammock: closed, peek, lidded, happy)
	Mouth string // "", "o" (yawn) or "smile"
	Legs  string // stand, a, b
	Bob   bool   // one pixel down, last leg row dropped (alternate walk steps)
	Hop   bool   // one pixel up (just before climbing in)
	Sway  int    // 0 or 1: the hammock and its occupant shift one pixel right
	Z     int    // 0..3 letters of "z z Z" on the top row
}

type grid [][]byte

func newGrid(w int) grid {
	g := make(grid, escRows)
	for r := range g {
		g[r] = make([]byte, w)
		for c := range g[r] {
			g[r][c] = '.'
		}
	}
	return g
}

func (g grid) put(r, c int, v byte) {
	if r >= 0 && r < len(g) && c >= 0 && c < len(g[r]) {
		g[r][c] = v
	}
}

// hammock draws the posts, ropes and fabric at column ox; occupied puts
// Esc in it with the given eyes.
func (g grid) hammock(ox, dx int, occupied bool, eyes string) {
	for r := 2; r < escRows; r++ {
		g.put(r, ox, 'P')
		g.put(r, ox+23, 'P')
	}
	g.put(2, ox+1, 'R')
	g.put(3, ox+2, 'R')
	g.put(4, ox+2+dx, 'R')
	g.put(5, ox+3+dx, 'R')
	g.put(2, ox+22, 'R')
	g.put(3, ox+21, 'R')
	g.put(4, ox+21, 'R')
	g.put(5, ox+20+dx, 'R')
	if occupied {
		x := ox + dx
		for c := 9; c <= 16; c++ {
			g.put(2, x+c, 'S')
		}
		for r := 3; r <= 5; r++ {
			g.put(r, x+8, 'S')
			for c := 9; c <= 16; c++ {
				g.put(r, x+c, 'T')
			}
			g.put(r, x+17, 'S')
		}
		switch eyes {
		case "", "closed", "happy":
			g.put(4, x+10, 'E')
			g.put(4, x+11, 'E')
			g.put(4, x+14, 'E')
			g.put(4, x+15, 'E')
		case "peek":
			g.put(4, x+10, 'E')
			g.put(4, x+11, 'E')
			g.put(3, x+14, 'S')
			g.put(4, x+14, 'E')
		default:
			g.put(3, x+11, 'S')
			g.put(4, x+11, 'E')
			g.put(3, x+14, 'S')
			g.put(4, x+14, 'E')
		}
		if eyes == "happy" {
			g.put(5, x+12, 'E')
			g.put(5, x+13, 'E')
		}
	}
	for i, span := range [][2]int{{3, 20}, {4, 19}, {6, 17}, {9, 14}} {
		for c := span[0]; c <= span[1]; c++ {
			v := byte('H')
			if c%3 == 0 {
				v = 'h'
			}
			g.put(6+i, ox+c+dx, v)
		}
	}
	if occupied {
		for r := 7; r <= 9; r++ {
			g.put(r, ox+dx+3, 'L')
		}
	}
}

// esc draws standing Esc with its left edge at column ox.
func (g grid) esc(ox int, p Pose) {
	eyes, ok := escEyes[p.Eyes]
	if !ok {
		eyes = escEyes["lidded"]
	}
	legs, ok := escLegs[p.Legs]
	if !ok {
		legs = escLegs["stand"]
	}
	mouth := ".TTTTTTTTTT."
	if p.Mouth == "o" || p.Mouth == "smile" {
		mouth = ".TTTTEETTTT."
	}
	wrap := func(s string) string { return "S" + s[1:11] + "S" }
	px := []string{".SSSSSSSSSS.", "SSTTTTTTTTSS", wrap(eyes[0]), wrap(eyes[1]), wrap(mouth),
		"SSTTTTTTTTSS", "SSSSSSSSSSSS", ".SSSSSSSSSS.", legs[0], legs[1]}
	oy := 2
	if p.Bob {
		oy++
	}
	if p.Hop {
		oy--
	}
	for r, row := range px {
		if p.Bob && r == 9 {
			continue
		}
		for c := 0; c < 12; c++ {
			if row[c] != '.' {
				g.put(oy+r, ox+c, row[c])
			}
		}
	}
}

// escCell is one terminal cell of a scene.
type escCell struct {
	ch     string
	fg, bg byte // pixel keys; 0 for none
	style  int  // for text cells: 0 none, 1..3 the z shades, 4 the ! mark
}

func (g grid) cells() [][]escCell {
	w := len(g[0])
	out := make([][]escCell, 0, escRows/2)
	for r := 0; r < escRows; r += 2 {
		row := make([]escCell, w)
		for c := 0; c < w; c++ {
			a, b := g[r][c], g[r+1][c]
			switch {
			case a == '.' && b == '.':
				row[c] = escCell{ch: " "}
			case a == '.':
				row[c] = escCell{ch: "▄", fg: b}
			case b == '.':
				row[c] = escCell{ch: "▀", fg: a}
			case a == b:
				row[c] = escCell{ch: "█", fg: a}
			default:
				row[c] = escCell{ch: "▀", fg: a, bg: b}
			}
		}
		out = append(out, row)
	}
	return out
}

// sleepZ writes up to three letters of "z z Z" on the top row from column zx.
func sleepZ(rows [][]escCell, n, zx int) {
	for i, ch := range []string{"z", "z", "Z"} {
		if i >= n || zx+2*i >= len(rows[0]) {
			break
		}
		rows[0][zx+2*i] = escCell{ch: ch, style: i + 1}
	}
}

// Sprite is the 24×6-cell header picture: Esc in the hammock, or standing
// in front of it.
func Sprite(p Pose) [][]escCell {
	g := newGrid(24)
	if p.Stand {
		g.hammock(0, 0, false, "")
		g.esc(p.X, p)
		rows := g.cells()
		if p.Eyes == "wide" && p.X+11 < 24 {
			rows[0][p.X+11] = escCell{ch: "!", style: 4}
		}
		return rows
	}
	eyes := p.Eyes
	if eyes == "" {
		eyes = "closed"
	}
	g.hammock(0, p.Sway, true, eyes)
	rows := g.cells()
	sleepZ(rows, p.Z, 16)
	return rows
}

// Scene is a wide strip for the handoff: the hammock on the left and Esc
// free to walk across (X), or back in the hammock.
func Scene(width int, p Pose, inHammock bool) [][]escCell {
	g := newGrid(width)
	eyes := p.Eyes
	if inHammock && eyes == "" {
		eyes = "closed"
	}
	g.hammock(0, p.Sway, inHammock, eyes)
	if !inHammock && p.X < width {
		g.esc(p.X, p)
	}
	rows := g.cells()
	sleepZ(rows, p.Z, 16)
	return rows
}

// escLines renders sprite rows as styled lines.
func (t Theme) escLines(rows [][]escCell) []line {
	out := make([]line, len(rows))
	for i, row := range rows {
		var l line
		for _, c := range row {
			st := t.Plain
			switch {
			case c.style == 1:
				st = t.Dim
			case c.style == 2:
				st = t.Plain
			case c.style == 3:
				st = t.Bold
			case c.style == 4:
				st = t.Warn.Bold(true)
			case c.fg != 0:
				st = lipgloss.NewStyle().Foreground(lipgloss.Color(escPalette[c.fg]))
				if c.bg != 0 {
					st = st.Background(lipgloss.Color(escPalette[c.bg]))
				}
			}
			// Merge runs of the same style so the output stays small.
			if n := len(l); n > 0 && sameEscStyle(row, c, l[n-1]) {
				l[n-1].s += c.ch
				continue
			}
			l = append(l, seg{st, c.ch})
		}
		out[i] = l
	}
	return out
}

// sameEscStyle is a cheap check that c can join the previous seg: only
// blank cells merge, which keeps the styles exact.
func sameEscStyle(_ []escCell, c escCell, prev seg) bool {
	return c.ch == " " && c.style == 0 && c.fg == 0 && prev.s != "" && prev.s[len(prev.s)-1] == ' '
}
