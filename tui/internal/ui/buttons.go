package ui

import (
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const buttonGap = 1

// button is a clickable "[label]".
type button struct {
	label string
	act   intent
}

func (b button) text() string { return "[" + b.label + "]" }

func (b button) width() int { return cellWidth(b.text()) }

// buttonsWidth is the width of the buttons laid out in a row.
func buttonsWidth(buttons []button) int {
	total := 0
	for i, b := range buttons {
		if i > 0 {
			total += buttonGap
		}
		total += b.width()
	}
	return total
}

// layoutButtons renders buttons side by side starting at (x, y) and returns the clickable areas.
func layoutButtons(buttons []button, x, y int) (string, []hit) {
	var row strings.Builder
	hits := make([]hit, 0, len(buttons))
	for i, b := range buttons {
		if i > 0 {
			row.WriteString(strings.Repeat(space, buttonGap))
			x += buttonGap
		}
		row.WriteString(theme.Button().Render(b.text()))
		hits = append(hits, hit{area: rect{x: x, y: y, w: b.width(), h: 1}, act: b.act})
		x += b.width()
	}
	return row.String(), hits
}

// fitButtons drops the buttons from the end of the list until the row fits in width.
func fitButtons(buttons []button, width int) []button {
	fitted := buttons
	for len(fitted) > 0 && buttonsWidth(fitted) > width {
		fitted = fitted[:len(fitted)-1]
	}
	return fitted
}
