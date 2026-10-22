package ui

import (
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// frame is one complete screen: every line, and what a tap on each area does.
type frame struct {
	lines []string
	hits  []hit
}

// View renders the panel.
func (m *Model) View() string {
	return strings.Join(m.frame().lines, newline)
}

// frame assembles the top bar, the body of the current screen, the input box when there is
// one, the hint bar and the status line.
func (m *Model) frame() frame {
	if m.width < minWidth || m.height < minHeight {
		return m.smallFrame()
	}
	top := m.topBar()
	height := m.bodyHeight()
	body := m.body(m.width, height)
	lines := append([]string{}, top.lines...)
	for _, line := range fitLines(body.lines, height) {
		lines = append(lines, padRight(line, m.width))
	}
	if m.hasInputBox() {
		lines = append(lines, m.inputLines()...)
	}
	lines = append(lines, m.hintBar(), m.statusLine())
	hits := append(top.hits, shifted(body.hits, 0, topBarHeight)...)
	return frame{lines: lines, hits: hits}
}

// smallFrame is shown when the window cannot hold the panel.
func (m *Model) smallFrame() frame {
	text := theme.Dim().Render(m.cat.Text(i18n.KeyTooSmall))
	lines := make([]string, max(m.height, 1))
	lines[len(lines)/2] = center(truncate(text, max(m.width, 1)), m.width)
	return frame{lines: lines}
}

// body draws the current screen.
func (m *Model) body(width, height int) block {
	switch m.top().screen {
	case screenHome:
		return m.homeBody(width, height)
	case screenDetail:
		return m.detailBody(width, height)
	case screenHelp:
		return m.helpBody(width, height)
	case screenDevices:
		return m.devicesBody(width, height)
	case screenAdd:
		return m.addBody(width, height)
	default:
		return m.menuBody(width, height)
	}
}

// addBody explains the "add device" step above its input.
func (m *Model) addBody(width, height int) block {
	rows := []string{}
	for _, line := range splitLines(strings.TrimSpace(m.cat.Text(i18n.KeyDescAdd))) {
		rows = append(rows, theme.Text().Render(line))
	}
	rows = append(rows, "", theme.Dim().Render(m.cat.Text(i18n.KeyStatusAdd)))
	panelWidth := min(width, menuMaxWidth)
	panelHeight := min(height, len(rows)+panelFrameRows+panelTitleRows)
	return centered(framePanel(panelSpec{
		title: m.cat.Text(i18n.KeyTitleAdd), rows: rows, width: panelWidth, height: panelHeight,
	}), width)
}

// inputLines is the rounded input box of the current screen.
func (m *Model) inputLines() []string {
	label, field := m.cat.Text(i18n.KeyWordFilter), m.filter.View()
	switch m.top().screen {
	case screenNewProject:
		label, field = m.cat.Text(i18n.KeyGhostNew2), m.input.View()
	case screenAdd:
		label, field = m.cat.Text(i18n.KeyGhostAdd), m.input.View()
	}
	return inputBox(label, field, m.width)
}
