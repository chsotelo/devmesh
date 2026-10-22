package ui

import (
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Glyphs and separators used all over the layout.
const (
	space      = " "
	newline    = "\n"
	ellipsis   = "…"
	middleDot  = " · "
	ruleGlyph  = "─"
	pointer    = "❯ "
	backArrow  = "‹ "
	crumbArrow = " › "
)

const (
	secondsPerMinute = 60
	secondsPerHour   = 3600
	secondsPerDay    = 86400
	noTime           = "-"
)

// cellWidth is the number of terminal cells a styled string takes.
func cellWidth(text string) int { return lipgloss.Width(text) }

// truncate cuts text to at most width cells, ending with an ellipsis when it was cut.
func truncate(text string, width int) string {
	if width <= 0 {
		return ""
	}
	if cellWidth(text) <= width {
		return text
	}
	return ansi.Truncate(text, width, ellipsis)
}

// padRight fills text with spaces up to width cells (cutting it when it is longer).
func padRight(text string, width int) string {
	text = truncate(text, width)
	missing := width - cellWidth(text)
	if missing <= 0 {
		return text
	}
	return text + strings.Repeat(space, missing)
}

// spread puts left and right at the two ends of a line of the given width. The left part
// is cut first when both do not fit; the right part is dropped only when it alone is too wide.
func spread(left, right string, width int) string {
	rightWidth := cellWidth(right)
	if rightWidth >= width {
		return padRight(truncate(right, width), width)
	}
	if rightWidth > 0 {
		rightWidth++
	}
	left = truncate(left, width-rightWidth)
	gap := width - cellWidth(left) - cellWidth(right)
	return left + strings.Repeat(space, max(gap, 0)) + right
}

// center places text in the middle of width cells.
func center(text string, width int) string {
	gap := width - cellWidth(text)
	if gap <= 0 {
		return truncate(text, width)
	}
	return strings.Repeat(space, gap/2) + text + strings.Repeat(space, gap-gap/2)
}

// ago formats a unix time as "40s", "5m", "2h" or "3d" relative to now.
func ago(now time.Time, then int64) string {
	if then <= 0 {
		return noTime
	}
	delta := max(now.Unix()-then, 0)
	switch {
	case delta < secondsPerMinute:
		return strconv.FormatInt(delta, 10) + "s"
	case delta < secondsPerHour:
		return strconv.FormatInt(delta/secondsPerMinute, 10) + "m"
	case delta < secondsPerDay:
		return strconv.FormatInt(delta/secondsPerHour, 10) + "h"
	default:
		return strconv.FormatInt(delta/secondsPerDay, 10) + "d"
	}
}

// fitLines pads or cuts a list of lines to exactly count lines.
func fitLines(lines []string, count int) []string {
	fitted := make([]string, count)
	copy(fitted, lines)
	return fitted
}

// splitLines splits a rendered block into lines.
func splitLines(rendered string) []string { return strings.Split(rendered, newline) }
