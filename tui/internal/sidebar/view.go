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
	// rowHeight is the lines of one terminal of the list: its line between two padding lines.
	rowHeight   = 3
	scrollTrack = "│"
	scrollThumb = "┃"
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
	marks := m.scrollMarks(end - m.top)
	lines := make([]string, 0, (end-m.top)*rowHeight)
	for i := m.top; i < end; i++ {
		lines = append(lines, m.rowBlock(i, marks[(i-m.top)*rowHeight:])...)
	}
	return lines
}

// scrollMarks is the last column of each visible line: a scrollbar when the list does not
// fit (thumb where the view is), else blank.
func (m *Model) scrollMarks(visibleRows int) []string {
	lines := visibleRows * rowHeight
	marks := make([]string, lines)
	total := len(m.rows) * rowHeight
	for i := range marks {
		marks[i] = space
	}
	if len(m.rows) <= visibleRows || total == 0 {
		return marks
	}
	from := m.top * rowHeight * lines / total
	size := max(lines*lines/total, 1)
	for i := range marks {
		marks[i] = theme.Faint().Render(scrollTrack)
		if i >= from && i < from+size {
			marks[i] = theme.Dim().Render(scrollThumb)
		}
	}
	return marks
}

// rowBlock is one terminal, rowHeight lines tall (a comfortable touch target): the row
// line in the middle, padding with the same background above and below.
func (m *Model) rowBlock(index int, marks []string) []string {
	block := make([]string, rowHeight)
	for line := range block {
		if line == rowHeight/2 {
			block[line] = m.rowLine(index, marks[line])
		} else {
			block[line] = m.rowPadding(index, marks[line])
		}
	}
	return block
}

func (m *Model) rowStyles(index int) (background, bar lipgloss.Style, mark string) {
	row := m.rows[index]
	background = lipgloss.NewStyle()
	if index == m.cursor {
		background = background.Background(lipgloss.Color(theme.ColorSelection))
	}
	bar, mark = theme.Faint(), idleBar
	if row.Session == m.shown {
		bar, mark = theme.Accent(), activeBar
	}
	return background, bar, mark
}

func (m *Model) rowPadding(index int, scroll string) string {
	background, barStyle, bar := m.rowStyles(index)
	fill := strings.Repeat(space, max(m.width-len(space)-2, 0))
	return paint(barStyle, background, bar+space) + paint(theme.Faint(), background, fill) + scroll
}

// rowLine is: bar, icon (machine color), name, program (dim), agent dot, like a VS Code
// terminal list ("api  claude"). The cursor row has the subtle background.
func (m *Model) rowLine(index int, scroll string) string {
	row := m.rows[index]
	background, barStyle, bar := m.rowStyles(index)
	nameStyle := theme.Dim()
	if row.Session == m.shown {
		nameStyle = theme.Bold()
	}
	textWidth := max(m.width-fixedCols, minNameCol)
	name := ansi.Truncate(row.Session, textWidth, ellipsis)
	command := ""
	if room := textWidth - lipgloss.Width(name) - len(cmdGap); row.Command != "" && room >= 3 {
		command = cmdGap + ansi.Truncate(row.Command, room, ellipsis)
	}
	pad := strings.Repeat(space, max(textWidth-lipgloss.Width(name)-lipgloss.Width(command), 0))
	parts := []string{
		paint(barStyle, background, bar+space),
		paint(theme.MachineColor(m.color), background, icon+space),
		paint(nameStyle, background, name),
		paint(theme.Faint(), background, command+pad+space),
		paint(dotStyle(row.Agent), background, dotOf(row.Agent)),
		scroll,
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
