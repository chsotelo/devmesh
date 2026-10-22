// Package theme defines the monochrome truecolor look of the panel (Grok Build inspired).
package theme

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// Palette, as hex truecolor. Machine colors are only small accent dots.
const (
	ColorBackground = "#0f0f0f"
	ColorSurface    = "#141414"
	ColorSelection  = "#242424"
	ColorBorder     = "#333333"
	ColorDim        = "#6c6c6c"
	ColorFaint      = "#505058"
	ColorText       = "#e1e1e1"
	ColorBright     = "#ffffff"
	ColorAccent     = "#7aa2f7"
	ColorWorking    = "#78aadc"
	ColorWaiting    = "#e6b450"
	ColorIdle       = "#78be8c"
	ColorError      = "#e06c75"
)

// Dot is the filled circle used for states; Ring is the empty one for offline machines.
const (
	Dot  = "●"
	Ring = "○"
)

var (
	text      = lipgloss.Color(ColorText)
	dim       = lipgloss.Color(ColorDim)
	faint     = lipgloss.Color(ColorFaint)
	accent    = lipgloss.Color(ColorAccent)
	border    = lipgloss.Color(ColorBorder)
	selection = lipgloss.Color(ColorSelection)
)

// Text is the normal foreground.
func Text() lipgloss.Style { return lipgloss.NewStyle().Foreground(text) }

// Bold is emphasized text.
func Bold() lipgloss.Style { return lipgloss.NewStyle().Foreground(text).Bold(true) }

// Dim is secondary text.
func Dim() lipgloss.Style { return lipgloss.NewStyle().Foreground(dim) }

// Faint is the quietest text (placeholders, thumbnails).
func Faint() lipgloss.Style { return lipgloss.NewStyle().Foreground(faint) }

// Accent is the highlight color: selection borders, counters, active keys.
func Accent() lipgloss.Style { return lipgloss.NewStyle().Foreground(accent) }

// Error is for failures shown in the status line.
func Error() lipgloss.Style { return lipgloss.NewStyle().Foreground(lipgloss.Color(ColorError)) }

// Selected marks the focused row.
func Selected() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(lipgloss.Color(ColorBright)).Background(selection)
}

// Button is a clickable label.
func Button() lipgloss.Style { return lipgloss.NewStyle().Foreground(text).Background(selection) }

// Card is the rounded frame of a terminal card.
func Card(selected bool, width int) lipgloss.Style {
	color := border
	if selected {
		color = accent
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(color).
		Width(width - 2)
}

// Panel is a plain rounded frame (detail pane, wizard boxes).
func Panel(width int) lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(border).
		Width(width - 2)
}

// StateColor returns the color of an agent state.
func StateColor(state feed.AgentState) lipgloss.Color {
	switch state {
	case feed.AgentWorking:
		return lipgloss.Color(ColorWorking)
	case feed.AgentWaiting:
		return lipgloss.Color(ColorWaiting)
	case feed.AgentIdle:
		return lipgloss.Color(ColorIdle)
	default:
		return dim
	}
}

// MachineDot colors a machine marker with its 256-color index, grey when unknown.
func MachineDot(color int, up bool) string {
	if !up {
		return lipgloss.NewStyle().Foreground(faint).Render(Ring)
	}
	if color <= 0 || color > 255 {
		return lipgloss.NewStyle().Foreground(dim).Render(Dot)
	}
	return lipgloss.NewStyle().Foreground(lipgloss.ANSIColor(color)).Render(Dot)
}
