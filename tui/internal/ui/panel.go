package ui

import (
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	panelFrameRows  = 2
	panelTitleRows  = 2
	panelPaddingCol = 2
	panelBorderCol  = 1
	boxCorners      = 2
)

// panelSpec describes a rounded panel with a title, rows and the clickable rows in it.
// Hits are given in row coordinates (y is the row index, x starts at 0).
type panelSpec struct {
	title  string
	rows   []string
	hits   []hit
	offset int
	width  int
	height int
}

// panelRoom is how many rows a panel of this height can show.
func panelRoom(height int) int { return max(height-panelFrameRows-panelTitleRows, 0) }

// windowFor returns the first visible row so that cursor stays in view.
func windowFor(cursor, room, total int) int {
	if room <= 0 || total <= room {
		return 0
	}
	return min(max(cursor-room+1, 0), total-room)
}

// framePanel draws the panel and moves the hits to block coordinates.
func framePanel(spec panelSpec) block {
	room := panelRoom(spec.height)
	end := min(spec.offset+room, len(spec.rows))
	visible := []string{}
	if spec.offset < end {
		visible = spec.rows[spec.offset:end]
	}
	inner := spec.width - panelPaddingCol - 2*panelBorderCol
	lines := []string{theme.Bold().Render(truncate(spec.title, inner)), theme.Faint().Render(strings.Repeat(ruleGlyph, inner))}
	lines = append(lines, visible...)
	framed := theme.Panel(spec.width).Padding(0, 1).Height(spec.height - panelFrameRows).Render(strings.Join(lines, newline))
	hits := shifted(clipped(spec.hits, spec.offset, room), panelBorderCol+1, panelBorderCol+panelTitleRows)
	return block{lines: splitLines(framed), hits: hits}
}

// rowHits makes one clickable full-width row per index in [0, count).
func rowHits(count, width int, act func(index int) intent) []hit {
	hits := make([]hit, 0, count)
	for i := range count {
		hits = append(hits, hit{area: rect{x: 0, y: i, w: width, h: 1}, act: act(i)})
	}
	return hits
}

// inputBox draws the rounded input at the bottom: "╭ label ───╮ / │ ❯ text │ / ╰───╯".
func inputBox(label, field string, width int) []string {
	border := theme.Faint()
	inner := width - boxCorners
	title := space + theme.Dim().Render(truncate(label, max(inner-3, 1))) + space
	top := border.Render("╭"+ruleGlyph) + title + border.Render(strings.Repeat(ruleGlyph, max(inner-cellWidth(title)-1, 0))+"╮")
	middle := border.Render("│") + padRight(space+field, inner) + border.Render("│")
	bottom := border.Render("╰" + strings.Repeat(ruleGlyph, inner) + "╯")
	return []string{top, middle, bottom}
}
