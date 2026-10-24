package sidebar

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

const wheelStep = 1

// Update handles keys, mouse and the poll results.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.keepVisible()
	case tickMsg:
		return m, m.startPoll()
	case pollMsg:
		return m, m.applyPoll(msg)
	case doneMsg:
		m.err = errorText(msg.err)
	case tea.KeyMsg:
		return m, m.handleKey(msg)
	case tea.MouseMsg:
		return m, m.handleMouse(msg)
	}
	return m, nil
}

func (m *Model) startPoll() tea.Cmd {
	if m.polling {
		return nil
	}
	m.polling = true
	return m.pollCmd()
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return feed.Clean(err.Error())
}

// applyPoll stores the new reading and decides what the right pane must show.
func (m *Model) applyPoll(msg pollMsg) tea.Cmd {
	m.polling = false
	next := tickCmd()
	if msg.err != nil {
		m.err = errorText(msg.err)
		return next
	}
	m.err = ""
	machine, found := msg.snap.FindMachine(m.host)
	m.online = found && machine.IsReachable()
	selected := m.selectedSession()
	m.rows = rowsOf(machine)
	m.color = machine.Color
	m.shown = msg.shown
	if !m.loaded {
		m.cursor = max(indexOf(m.rows, m.shown), 0)
	} else if at := indexOf(m.rows, selected); at >= 0 {
		m.cursor = at
	}
	m.loaded = true
	m.cursor = min(m.cursor, max(len(m.rows)-1, 0))
	m.keepVisible()
	decided := m.decide()
	return tea.Batch(next, decided, m.remember())
}

func (m *Model) selectedSession() string {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return ""
	}
	return m.rows[m.cursor].Session
}

// decide keeps the right pane coherent with the machine: a message when it is off or has
// no terminals, else the first terminal when nothing is shown (or the shown one is gone).
func (m *Model) decide() tea.Cmd {
	switch {
	case !m.online:
		return m.hold(source.HoldOffline)
	case len(m.rows) == 0:
		return m.hold(source.HoldEmpty)
	}
	m.held = ""
	if m.shown != "" && indexOf(m.rows, m.shown) >= 0 {
		m.misses = 0
		return nil
	}
	if m.shown != "" {
		m.misses++
		if m.misses < missesToSwap {
			return nil
		}
	}
	m.misses = 0
	m.shown = m.rows[0].Session
	return m.showCmd(m.rows[0], false)
}

func (m *Model) hold(kind string) tea.Cmd {
	m.misses = 0
	if m.held == kind {
		return nil
	}
	m.held = kind
	m.shown = ""
	return m.holdCmd(kind)
}

func (m *Model) handleKey(msg tea.KeyMsg) tea.Cmd {
	switch msg.String() {
	case "up", "k":
		m.move(-1)
	case "down", "j":
		m.move(1)
	case "home", "g":
		m.move(-len(m.rows))
	case "end", "G":
		m.move(len(m.rows))
	case "enter", " ":
		return m.choose(m.cursor)
	case "r":
		return m.startPoll()
	case "n", "+":
		return m.actCmd(source.ActAdd)
	case "x", "delete":
		return m.actCmd(source.ActDelete)
	}
	return nil
}

func (m *Model) move(delta int) {
	if len(m.rows) == 0 {
		return
	}
	m.cursor = min(max(m.cursor+delta, 0), len(m.rows)-1)
	m.keepVisible()
}

// choose shows the terminal of a row and moves the keyboard to it.
func (m *Model) choose(index int) tea.Cmd {
	if index < 0 || index >= len(m.rows) {
		return nil
	}
	m.cursor = index
	m.shown = m.rows[index].Session
	m.held = ""
	m.misses = 0
	return m.showCmd(m.rows[index], true)
}

func (m *Model) handleMouse(msg tea.MouseMsg) tea.Cmd {
	switch {
	case msg.Button == tea.MouseButtonWheelUp:
		m.scroll(-wheelStep)
	case msg.Button == tea.MouseButtonWheelDown:
		m.scroll(wheelStep)
	case msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft:
		if msg.Y < buttonHeight {
			return m.clickButton(msg.X)
		}
		if msg.Y < buttonLines {
			return nil
		}
		return m.choose(m.top + (msg.Y-buttonLines)/rowHeight)
	}
	return nil
}

// clickButton runs the button of the top line under column x.
func (m *Model) clickButton(x int) tea.Cmd {
	for _, button := range m.buttons() {
		if x >= button.from && x < button.to {
			return m.actCmd(button.action)
		}
	}
	return nil
}

func (m *Model) scroll(lines int) {
	m.top = min(max(m.top+lines, 0), max(len(m.rows)-m.listHeight(), 0))
}

// listHeight is how many terminals fit: all lines but the buttons (and the error line when
// there is one), rowHeight lines each.
func (m *Model) listHeight() int {
	height := m.height - buttonLines
	if m.err != "" {
		height--
	}
	return max(height/rowHeight, 1)
}

func (m *Model) keepVisible() {
	height := m.listHeight()
	if m.cursor < m.top {
		m.top = m.cursor
	}
	if m.cursor >= m.top+height {
		m.top = m.cursor - height + 1
	}
	m.top = max(m.top, 0)
}
