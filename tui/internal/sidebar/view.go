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
	// buttonLines is the top line with the buttons; the rows start below it.
	buttonLines = 1
	addLabel    = "+ "
	buttonGap   = "  "
)

// button is a clickable label of the top line, from column from up to (not including) to.
type button struct {
	label  string
	action string
	from   int
	to     int
}

// buttons lays out the top line: " + New  Delete".
func (m *Model) buttons() []button {
	labels := []struct{ label, action string }{
		{addLabel + m.cat.Text(i18n.KeyBtnNew), source.ActAdd},
		{m.cat.Text(i18n.KeyBtnDelete), source.ActDelete},
	}
	at := len(space)
	out := make([]button, 0, len(labels))
	for _, item := range labels {
		width := lipgloss.Width(item.label)
		out = append(out, button{label: item.label, action: item.action, from: at, to: at + width})
		at += width + len(buttonGap)
	}
	return out
}

func (m *Model) buttonLine() string {
	parts := []string{space}
	for i, b := range m.buttons() {
		if i > 0 {
			parts = append(parts, buttonGap)
		}
		parts = append(parts, theme.Accent().Render(b.label))
	}
	return ansi.Truncate(strings.Join(parts, ""), m.width, ellipsis)
}

// View draws the list.
func (m *Model) View() string {
	if m.width <= 0 {
		return ""
	}
	lines := []string{m.buttonLine()}
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
