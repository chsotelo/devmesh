package sidebar

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/chsotelo/devmesh/tui/internal/i18n"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// handleKey routes a key to the terminal list or to the Claude screens.
func (m *Model) handleKey(msg tea.KeyMsg) tea.Cmd {
	if cmd, handled := m.headerKey(msg.String()); handled {
		return cmd
	}
	if m.claude.mode == modeTerminals {
		return m.handleTerminalKey(msg)
	}
	return m.handleClaudeKey(msg)
}

// handleMouse routes a tap or the wheel the same way.
func (m *Model) handleMouse(msg tea.MouseMsg) tea.Cmd {
	if m.claude.mode == modeTerminals {
		return m.handleTerminalMouse(msg)
	}
	switch {
	case msg.Button == tea.MouseButtonWheelUp:
		m.claude.top = max(m.claude.top-wheelStep, 0)
	case msg.Button == tea.MouseButtonWheelDown:
		m.claude.top += wheelStep
	case msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft:
		return m.tap(msg.X, msg.Y)
	}
	return nil
}

// tap runs what is drawn at (x, y): a button or footer item, else the row.
func (m *Model) tap(x, y int) tea.Cmd {
	line, found := m.lineAt(y)
	if !found {
		return nil
	}
	for _, seg := range line.segs {
		if x >= seg.from && x < seg.to {
			return m.runAction(seg.act)
		}
	}
	if line.act.kind != actNone {
		return m.runAction(line.act)
	}
	if line.idx >= 0 {
		return m.activate(line.idx)
	}
	return nil
}

func (m *Model) handleClaudeKey(msg tea.KeyMsg) tea.Cmd {
	name := msg.String()
	switch name {
	case "esc":
		if m.claude.mode != modeClaude {
			return m.goMode(modeClaude)
		}
		return nil
	case "up", "down", "pgup", "pgdown":
		m.moveClaude(map[string]int{"up": -1, "down": 1, "pgup": -pageRows, "pgdown": pageRows}[name])
		return nil
	case "enter":
		return m.activate(m.cursorIndex(m.items()))
	}
	if m.typing() {
		return m.typeInto(msg)
	}
	return m.claudeShortcut(name)
}

const pageRows = 4

// claudeShortcut are the letters of the Claude home.
func (m *Model) claudeShortcut(name string) tea.Cmd {
	if m.claude.mode == modePower {
		return m.powerShortcut(name)
	}
	switch name {
	case "j":
		m.moveClaude(1)
	case "k":
		m.moveClaude(-1)
	case " ":
		return m.activate(m.cursorIndex(m.items()))
	case "r":
		return m.startPoll()
	case "n", "+":
		return m.runAction(cact{kind: actNew})
	case "t":
		return m.runAction(cact{kind: actTerminals})
	case "p":
		return m.runAction(cact{kind: actPower})
	case "H":
		return m.runAction(cact{kind: actHistory})
	case "x", "delete":
		if session, found := m.selectedClaude(); found {
			return m.runAction(cact{kind: actStop, arg: session.ID})
		}
	case "m":
		return m.moveSelected()
	}
	return nil
}

// typeInto feeds a key to the input box; the rows start again from the first one.
func (m *Model) typeInto(msg tea.KeyMsg) tea.Cmd {
	before := m.claude.input.Value()
	updated, cmd := m.claude.input.Update(msg)
	m.claude.input = updated
	if m.claude.input.Value() != before {
		m.claude.cur, m.claude.top = 0, 0
	}
	return cmd
}

// moveClaude moves the cursor by delta rows.
func (m *Model) moveClaude(delta int) {
	items := m.items()
	if len(items) == 0 {
		return
	}
	at := min(max(m.cursorIndex(items)+delta, 0), len(items)-1)
	m.claude.cur = at
	if m.claude.mode == modeClaude {
		m.claude.sel = items[at].id
	}
	m.keepClaudeVisible()
}

// activate is Enter or a tap on a row.
func (m *Model) activate(index int) tea.Cmd {
	items := m.items()
	if index < 0 || index >= len(items) {
		return nil
	}
	item := items[index]
	m.claude.cur = index
	switch m.claude.mode {
	case modeClaude:
		m.claude.sel = item.id
		for _, session := range m.sessions() {
			if session.ID == item.id {
				return m.chooseSession(session)
			}
		}
	case modeHistory:
		return nil
	case modeTargets:
		return m.pickTarget(item.id)
	case modeNew:
		return m.createClaude(item.id)
	case modePower:
		return m.pickPower(item.id)
	}
	return nil
}

// pickTarget runs the move (or the resume) the targets list was opened for.
func (m *Model) pickTarget(host string) tea.Cmd {
	for _, target := range m.targets() {
		if target.Machine.Name == host && !target.Eligible() {
			m.err = host + " · " + m.reason(target.Why)
			return nil
		}
	}
	if m.claude.pending.resume {
		return m.resumeClaude(m.claude.pending.id, host)
	}
	return m.moveTo(m.claude.pending.id, host)
}

// perform runs the action of a button, a footer item or a line.
func (m *Model) runAction(act cact) tea.Cmd {
	switch act.kind {
	case actStop:
		return m.stopSessions(m.sessionsByID(act.arg))
	case actStopIdle:
		return m.stopSessions(feed.StaleSessions(m.sessions()))
	case actMoveTo:
		return m.moveTo(act.arg, act.extra)
	case actMoveMenu:
		return m.openTargets(act.arg, false)
	case actResume:
		return m.resumeClaude(act.arg, act.extra)
	case actResumeMenu:
		return m.openTargets(act.arg, true)
	case actNew:
		return m.startNew()
	case actTerminals:
		return m.goMode(modeTerminals)
	case actHistory:
		return m.goMode(modeHistory)
	case actBack:
		return m.goMode(modeClaude)
	case actPower:
		return m.openPower()
	}
	return nil
}

func (m *Model) sessionsByID(id string) []feed.ClaudeSession {
	for _, session := range m.sessions() {
		if session.ID == id {
			return []feed.ClaudeSession{session}
		}
	}
	return nil
}

// startNew opens the new session form when the machine can run Claude.
func (m *Model) startNew() tea.Cmd {
	switch {
	case !m.online:
		m.err = m.cat.Text(i18n.KeyOffline)
		return nil
	case !m.claude.machine.HasClaude && !m.claude.machine.ClaudeKnown:
		m.err = m.cat.Text(i18n.KeyClOutdated)
		return nil
	case !m.claude.machine.HasClaude:
		m.err = m.cat.Text(i18n.KeyClNoClaude)
		return nil
	}
	return m.goMode(modeNew)
}

// applyMesh stores the reading of the whole mesh.
func (m *Model) applyMesh(msg meshMsg) {
	m.claude.meshBusy = false
	if msg.err == nil {
		m.claude.mesh = msg.snap
	}
}

func (m *Model) applyProjects(msg projectsMsg) {
	m.claude.projectsOK = true
	if msg.err != nil {
		m.err = errorText(msg.err)
		return
	}
	m.claude.projects = msg.names
}
