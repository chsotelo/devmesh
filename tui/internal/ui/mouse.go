package ui

import (
	tea "github.com/charmbracelet/bubbletea"
)

// handleMouse maps taps to the intent under the finger and the wheel to scrolling.
func (m *Model) handleMouse(msg tea.MouseMsg) tea.Cmd {
	switch {
	case msg.Button == tea.MouseButtonWheelUp:
		return m.scrollBy(-wheelStep)
	case msg.Button == tea.MouseButtonWheelDown:
		return m.scrollBy(wheelStep)
	case msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft:
		return m.tap(msg.X, msg.Y)
	}
	return nil
}

// tap performs what is drawn at (x, y), if anything.
func (m *Model) tap(x, y int) tea.Cmd {
	for _, h := range m.frame().hits {
		if h.area.contains(x, y) {
			return m.applyIntent(h.act)
		}
	}
	return nil
}

// scrollBy scrolls the list under the wheel.
func (m *Model) scrollBy(lines int) tea.Cmd {
	switch m.top().screen {
	case screenHome:
		m.scrollClaude(lines / wheelStep)
		return m.refreshShots()
	case screenTerminals:
		layout := m.homeLayout()
		m.scroll = clampScroll(m.scroll+lines, len(layout.lines), m.bodyHeight())
		return m.refreshShots()
	case screenDevices:
		m.cursor = max(m.cursor+lines, 0)
	case screenMachine, screenNewMachine, screenNewProject, screenPick, screenMove, screenHistory, screenHistoryItem, screenClaudeNew:
		m.moveCursor(lines / wheelStep)
	}
	return nil
}
