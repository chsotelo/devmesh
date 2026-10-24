package sidebar

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	icon       = ">_"
	activeBar  = "▎"
	idleBar    = " "
	ellipsis   = "…"
	space      = " "
	noDot      = " "
	fixedCols  = 8 // bar, space, icon (2), space, space, dot, space
	minNameCol = 1
	cmdGap     = "  "
	// The buttons are buttonHeight lines tall (a padding line above and below the label,
	// a comfortable touch target), then one empty line; the rows start below.
	buttonHeight = 3
	buttonLines  = buttonHeight + 1
	buttonMargin = 1
	buttonGap    = 1
	addLabel     = "+ "
)

// button is a clickable box of the top lines, from column from up to (not including) to.
type button struct {
	label  string
	action string
	from   int
	to     int
}

// buttons splits the width between the buttons: "[  + New  ] [ Delete ]".
func (m *Model) buttons() []button {
	labels := []struct{ label, action string }{
		{addLabel + m.cat.Text(i18n.KeyBtnNew), source.ActAdd},
		{m.cat.Text(i18n.KeyBtnDelete), source.ActDelete},
	}
	room := m.width - 2*buttonMargin - buttonGap*(len(labels)-1)
	at := buttonMargin
	out := make([]button, 0, len(labels))
	for i, item := range labels {
		width := max(room/len(labels), 1)
		if i == len(labels)-1 {
			width = max(room-width*(len(labels)-1), 1)
		}
		out = append(out, button{label: item.label, action: item.action, from: at, to: at + width})
		at += width + buttonGap
	}
	return out
}

// buttonBlock draws the buttons: the label centered on the middle line, padding around.
func (m *Model) buttonBlock() []string {
	buttons := m.buttons()
	lines := make([]string, 0, buttonLines)
	for line := 0; line < buttonHeight; line++ {
		parts := []string{strings.Repeat(space, buttonMargin)}
		for i, b := range buttons {
			if i > 0 {
				parts = append(parts, strings.Repeat(space, buttonGap))
			}
			text := ""
			if line == buttonHeight/2 {
				text = b.label
			}
			parts = append(parts, theme.Button().Render(centered(text, b.to-b.from)))
		}
		lines = append(lines, ansi.Truncate(strings.Join(parts, ""), m.width, ""))
	}
	return append(lines, "")
}

// centered pads text to width with the label in the middle (cut when it does not fit).
func centered(text string, width int) string {
	text = ansi.Truncate(text, width, "")
	left := (width - lipgloss.Width(text)) / 2
	right := width - lipgloss.Width(text) - left
	return strings.Repeat(space, left) + text + strings.Repeat(space, right)
}

// View draws the list.
func (m *Model) View() string {
	if m.width <= 0 {
		return ""
	}
	lines := m.buttonBlock()
	switch {
	case !m.loaded:
		lines = append(lines, m.message(i18n.KeyLoading))
	case !m.online:
		lines = append(lines, m.message(i18n.KeyOffline))
	case len(m.rows) == 0:
		lines = append(lines, m.message(i18n.KeyNoTerminals))
	default:
		lines = append(lines, m.rowLines()...)
	}
	if m.err != "" {
		lines = append(lines, theme.Error().Render(ansi.Truncate(space+m.err, m.width, ellipsis)))
	}
	return strings.Join(lines, "\n")
}

func (m *Model) message(key string) string {
	return theme.Faint().Render(ansi.Truncate(space+m.cat.Text(key), m.width, ellipsis))
}

func (m *Model) rowLines() []string {
	end := min(m.top+m.listHeight(), len(m.rows))
	lines := make([]string, 0, end-m.top)
	for i := m.top; i < end; i++ {
		lines = append(lines, m.rowLine(i))
	}
	return lines
}

// rowLine is: bar, icon (machine color), name, program (dim), agent dot, like a VS Code
// terminal list ("api  claude"). The cursor row has the subtle background.
func (m *Model) rowLine(index int) string {
	row := m.rows[index]
	isShown := row.Session == m.shown
	background := lipgloss.NewStyle()
	if index == m.cursor {
		background = background.Background(lipgloss.Color(theme.ColorSelection))
	}
	nameStyle := theme.Dim()
	barStyle := theme.Faint()
	if isShown {
		nameStyle = theme.Bold()
		barStyle = theme.Accent()
	}
	textWidth := max(m.width-fixedCols, minNameCol)
	name := ansi.Truncate(row.Session, textWidth, ellipsis)
	command := ""
	if room := textWidth - lipgloss.Width(name) - len(cmdGap); row.Command != "" && room >= 3 {
		command = cmdGap + ansi.Truncate(row.Command, room, ellipsis)
	}
	pad := strings.Repeat(space, max(textWidth-lipgloss.Width(name)-lipgloss.Width(command), 0))
	bar := idleBar
	if isShown {
		bar = activeBar
	}
	parts := []string{
		paint(barStyle, background, bar+space),
		paint(theme.MachineColor(m.color), background, icon+space),
		paint(nameStyle, background, name),
		paint(theme.Faint(), background, command+pad+space),
		paint(dotStyle(row.Agent), background, dotOf(row.Agent)),
		paint(theme.Faint(), background, space),
	}
	return strings.Join(parts, "")
}

func paint(style, background lipgloss.Style, text string) string {
	return style.Inherit(background).Render(text)
}

func dotOf(state feed.AgentState) string {
	if state == feed.AgentNone {
		return noDot
	}
	return theme.Dot
}

func dotStyle(state feed.AgentState) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(theme.StateColor(state))
}
