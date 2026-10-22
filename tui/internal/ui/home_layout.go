package ui

import (
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	minCardWidth   = 33
	cardGap        = 1
	maxColumns     = 4
	minThumbLines  = 3
	maxThumbLines  = 10
	sectionPadding = 1
	selectionMark  = "▌"
	prefixMachine  = "m:"
	prefixTerminal = "t:"
)

type cellKind int

const (
	cellMachine cellKind = iota
	cellTerminal
)

// cell is something on the home screen the cursor can rest on.
type cell struct {
	key  string
	kind cellKind
	host string
	term feed.Terminal
	area rect
}

// homeParams are the inputs of the home layout.
type homeParams struct {
	snap     feed.Snapshot
	shots    map[string]shot
	filter   string
	width    int
	height   int
	selected string
	now      time.Time
	cat      i18n.Catalog
}

// homeLayout is the whole (scrollable) home body.
type homeLayout struct {
	lines   []string
	cells   []cell
	hits    []hit
	columns int
	body    int
}

func machineKey(name string) string { return prefixMachine + name }

func terminalKey(term feed.Terminal) string { return prefixTerminal + term.Key() }

// columnsFor picks how many cards fit side by side: one on phones, two on a portrait
// tablet, more on wide screens.
func columnsFor(width int) int {
	return min(max((width+cardGap)/(minCardWidth+cardGap), 1), maxColumns)
}

// cardWidths splits width into the card widths of one row, sharing the remainder.
func cardWidths(width, columns int) []int {
	usable := width - cardGap*(columns-1)
	base, extra := usable/columns, usable%columns
	widths := make([]int, columns)
	for i := range widths {
		widths[i] = base
		if i < extra {
			widths[i]++
		}
	}
	return widths
}

// bodyLinesFor adapts the thumbnail height to the room: about two rows of cards fit.
func bodyLinesFor(height int) int {
	return min(max((height-4)/2-cardBorderRows-cardHeaderRows, minThumbLines), maxThumbLines)
}

// termMatches reports whether a terminal passes the filter (case insensitive).
func termMatches(machine string, term feed.Terminal, filter string) bool {
	if filter == "" {
		return true
	}
	hay := strings.ToLower(strings.Join([]string{machine, term.Session, term.Command, string(term.Agent), term.Origin}, space))
	return strings.Contains(hay, strings.ToLower(filter))
}

func filterTerminals(machine feed.Machine, filter string) []feed.Terminal {
	kept := make([]feed.Terminal, 0, len(machine.Terminals))
	for _, term := range machine.Terminals {
		if termMatches(machine.Name, term, filter) {
			kept = append(kept, term)
		}
	}
	return kept
}

// layoutHome draws every machine section into full-height lines and records the cells.
func layoutHome(p homeParams) homeLayout {
	layout := homeLayout{columns: columnsFor(p.width), body: bodyLinesFor(p.height)}
	for _, machine := range p.snap.Machines {
		terms := filterTerminals(machine, p.filter)
		if p.filter != "" && len(terms) == 0 {
			continue
		}
		layout.addSection(p, machine, terms)
	}
	return layout
}

func (l *homeLayout) addSection(p homeParams, machine feed.Machine, terms []feed.Terminal) {
	header, headerHits := renderMachineHeader(machine, len(terms), p, len(l.lines))
	l.cells = append(l.cells, cell{key: machineKey(machine.Name), kind: cellMachine, host: machine.Name,
		area: rect{x: 0, y: len(l.lines), w: p.width, h: 1}})
	l.hits = append(l.hits, headerHits...)
	l.lines = append(l.lines, header)
	switch {
	case !machine.IsReachable():
		l.lines = append(l.lines, padRight(note(p.cat, i18n.KeyOfflineHint), p.width))
	case len(terms) == 0 && p.filter == "":
		l.lines = append(l.lines, padRight(note(p.cat, i18n.KeyNoTerminals)+middleDot+p.cat.Text(i18n.KeyNoTerminalsHint), p.width))
	default:
		l.addCardRows(p, terms)
	}
	for range sectionPadding {
		l.lines = append(l.lines, strings.Repeat(space, p.width))
	}
}

func note(cat i18n.Catalog, key string) string {
	return space + space + theme.Faint().Render(cat.Text(key))
}

// addCardRows lays the cards of one machine in a grid.
func (l *homeLayout) addCardRows(p homeParams, terms []feed.Terminal) {
	widths := cardWidths(p.width, l.columns)
	for start := 0; start < len(terms); start += l.columns {
		end := min(start+l.columns, len(terms))
		cards := make([]string, 0, 2*l.columns)
		x := 0
		for i, term := range terms[start:end] {
			key := terminalKey(term)
			card := renderCard(cardSpec{term: term, selected: key == p.selected, width: widths[i],
				body: l.body, thumb: p.shots[term.Key()].lines, now: p.now, cat: p.cat})
			area := rect{x: x, y: len(l.lines), w: widths[i], h: cardHeight(l.body)}
			l.cells = append(l.cells, cell{key: key, kind: cellTerminal, host: term.Host, term: term, area: area})
			l.hits = append(l.hits, hit{area: area, act: intent{verb: verbSelect, arg: key}})
			cards = append(cards, card, strings.Repeat(space, cardGap))
			x += widths[i] + cardGap
		}
		row := lipgloss.JoinHorizontal(lipgloss.Top, cards[:len(cards)-1]...)
		for _, line := range splitLines(row) {
			l.lines = append(l.lines, padRight(line, p.width))
		}
	}
}

// renderMachineHeader draws "▌ ● laptop  3 terminals      [new]" and its buttons.
func renderMachineHeader(machine feed.Machine, shown int, p homeParams, row int) (string, []hit) {
	marker := space
	if p.selected == machineKey(machine.Name) {
		marker = theme.Accent().Render(selectionMark)
	}
	name := theme.Bold().Render(machine.Name)
	if !machine.IsReachable() {
		name = theme.Dim().Render(machine.Name)
	}
	left := marker + theme.MachineDot(machine.Color, machine.IsReachable()) + space + name
	if machine.IsReachable() {
		left += space + space + theme.Dim().Render(p.cat.Count(shown, i18n.KeyTerminalOne, i18n.KeyTerminalMany))
	} else {
		left += space + space + theme.Faint().Render(p.cat.Text(i18n.KeyOffline))
	}
	label, act := p.cat.Text(i18n.KeyWordWake), intent{verb: verbWake, arg: machine.Name}
	if machine.IsReachable() {
		label, act = p.cat.Text(i18n.KeyWordNew), intent{verb: verbNewOn, arg: machine.Name}
	}
	button := theme.Button().Render("[" + label + "]")
	width := cellWidth(button)
	hits := []hit{
		{area: rect{x: p.width - width, y: row, w: width, h: 1}, act: act},
		{area: rect{x: 0, y: row, w: p.width - width, h: 1}, act: intent{verb: verbSelect, arg: machineKey(machine.Name)}},
	}
	return spread(left, button, p.width), hits
}
