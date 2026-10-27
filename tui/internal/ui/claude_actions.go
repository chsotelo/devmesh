package ui

import (
	"context"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

// claudeBudget is how long a Claude action may run (stopping waits, moving copies).
const claudeBudget = 130 * time.Second

// claudeDoneMsg is the end of an action on a Claude session. The ones that start a session
// carry the tmux session to open on host.
type claudeDoneMsg struct {
	err     error
	host    string
	sid     string
	session string
}

// applyClaudeIntent runs the verbs of the Claude screens; other verbs do nothing.
func (m *Model) applyClaudeIntent(act intent) tea.Cmd {
	switch act.verb {
	case verbSay:
		m.say(act.arg, true)
	case verbOpenClaude:
		return m.openClaude()
	case verbViewMachine:
		m.viewMachine(act.arg)
		return m.refreshShots()
	case verbPickMachine:
		return m.openTyped(route{screen: screenPick}, "")
	case verbStop:
		return m.stopSelected()
	case verbStopIdle:
		return m.stopStale()
	case verbMoveTo:
		return m.moveSession(act.arg, act.extra)
	case verbMoveMenu:
		return m.openMoveMenu()
	case verbHistory:
		return m.openTyped(route{screen: screenHistory, arg: m.claudeHost}, "")
	case verbTerminals:
		m.push(route{screen: screenTerminals})
		m.resolveSelection()
		return m.refreshShots()
	case verbHistoryItem:
		m.push(route{screen: screenHistoryItem, arg: act.arg})
		m.input.Blur()
	case verbResume:
		return m.resume(act.arg, act.extra)
	case verbClaudeCreate:
		return m.createClaude(act.arg)
	}
	return nil
}

// openTyped pushes a screen that has the input box and gives the input its first text.
func (m *Model) openTyped(next route, text string) tea.Cmd {
	m.push(next)
	m.input.SetValue(text)
	return tea.Batch(m.input.Focus(), textinput.Blink)
}

// viewMachine shows the sessions of another machine; from the picker it also closes it.
func (m *Model) viewMachine(host string) {
	if _, found := m.snap.FindMachine(host); !found {
		return
	}
	if m.top().screen == screenPick {
		m.pop()
	}
	m.claudeHost, m.claudeScroll = host, 0
	m.resolveClaude()
}

// tapClaude is a tap on a session row: the first tap selects it, tapping it again opens it.
func (m *Model) tapClaude(id string) tea.Cmd {
	if id == m.claudeSel {
		return m.activateClaude()
	}
	m.claudeSel = id
	m.ensureClaudeVisible()
	return m.refreshShots()
}

// activateClaude opens the selected session: the real terminal when the pane is on screen,
// else the full screen session (with its actions) first.
func (m *Model) activateClaude() tea.Cmd {
	session, found := m.selectedSession()
	if !found {
		return nil
	}
	if !session.Openable() {
		m.say(m.cat.Text(i18n.KeyClOutside), true)
		if !m.wide() {
			m.push(route{screen: screenSession, arg: session.ID})
		}
		return nil
	}
	if m.wide() {
		return m.openSession(session.Machine, session.TmuxSession(), m.claudeTerminal(session).Window)
	}
	m.push(route{screen: screenSession, arg: session.ID})
	return m.refreshShots()
}

// openClaude attaches to the selected session itself (the "open" button and key).
func (m *Model) openClaude() tea.Cmd {
	session, found := m.selectedSession()
	switch {
	case !found:
		return nil
	case !session.Openable():
		m.say(m.cat.Text(i18n.KeyClOutside), true)
		return nil
	}
	return m.openSession(session.Machine, session.TmuxSession(), m.claudeTerminal(session).Window)
}

// openSession opens a tmux session through the same path as any terminal.
func (m *Model) openSession(host, session, window string) tea.Cmd {
	return m.openTerminalCommand(feed.Terminal{Host: host, Session: session, Window: window})
}

// moveClaudeSelection walks the home: left and right change machine, up and down the rows.
func (m *Model) moveClaudeSelection(direction string) {
	switch direction {
	case moveLeft, moveRight:
		m.stepMachine(listStep(direction))
		return
	}
	list := m.sessions()
	if len(list) == 0 {
		return
	}
	at := 0
	for i, session := range list {
		if session.ID == m.claudeSel {
			at = i
		}
	}
	switch direction {
	case moveFirst:
		at = 0
	case moveLast:
		at = len(list) - 1
	default:
		at = min(max(at+listStep(direction), 0), len(list)-1)
	}
	m.claudeSel = list[at].ID
	m.ensureClaudeVisible()
}

// stepMachine moves the viewed machine by step in the list of machines.
func (m *Model) stepMachine(step int) {
	machines := m.snap.Machines
	if len(machines) == 0 {
		return
	}
	at := 0
	for i, machine := range machines {
		if machine.Name == m.claudeHost {
			at = i
		}
	}
	m.viewMachine(machines[(at+step+len(machines))%len(machines)].Name)
}

// ensureClaudeVisible scrolls the rows so the selected one is on screen.
func (m *Model) ensureClaudeVisible() {
	list := m.sessions()
	visible := claudeGeometryFor(m.bodyHeight(), len(feed.StaleSessions(list)) > 0).visibleRows()
	for i, session := range list {
		switch {
		case session.ID != m.claudeSel:
		case i < m.claudeScroll:
			m.claudeScroll = i
		case i >= m.claudeScroll+visible:
			m.claudeScroll = i - visible + 1
		}
	}
	m.claudeScroll = min(max(m.claudeScroll, 0), max(len(list)-visible, 0))
}

// scrollClaude scrolls the rows under the wheel.
func (m *Model) scrollClaude(lines int) {
	list := m.sessions()
	visible := claudeGeometryFor(m.bodyHeight(), len(feed.StaleSessions(list)) > 0).visibleRows()
	m.claudeScroll = min(max(m.claudeScroll+lines, 0), max(len(list)-visible, 0))
}

// runClaude runs an action on a Claude session in the background; done says what comes
// back (the session to open, when the action starts one).
func (m *Model) runClaude(work func(ctx context.Context) (string, error), done claudeDoneMsg) tea.Cmd {
	if m.claudeBusy {
		m.say(m.cat.Text(i18n.KeyClWait), false)
		return nil
	}
	m.claudeBusy = true
	m.say(m.cat.Text(i18n.KeyClWait), false)
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), claudeBudget)
		defer cancel()
		done.session, done.err = work(ctx)
		return done
	}
}

// applyClaudeDone ends an action: report a failure, else show the new place of the session
// (opening it when the action started one) and read the mesh again.
func (m *Model) applyClaudeDone(msg claudeDoneMsg) tea.Cmd {
	m.claudeBusy = false
	if msg.err != nil {
		m.say(m.failure(msg.err), true)
		return m.fetchFeed()
	}
	m.notice = ""
	m.routes = m.routes[:1]
	if msg.host != "" {
		m.claudeHost = msg.host
	}
	if msg.sid != "" {
		m.claudeSel = msg.sid
	}
	cmds := []tea.Cmd{m.fetchFeed()}
	if msg.session != "" {
		cmds = append(cmds, m.openSession(msg.host, msg.session, ""))
	}
	return tea.Batch(cmds...)
}

// stopSelected stops the selected session.
func (m *Model) stopSelected() tea.Cmd {
	session, found := m.selectedSession()
	if !found {
		return nil
	}
	return m.stopSessions([]feed.ClaudeSession{session})
}

// stopStale stops every session of the machine that has been idle for over an hour.
func (m *Model) stopStale() tea.Cmd {
	return m.stopSessions(feed.StaleSessions(m.sessions()))
}

func (m *Model) stopSessions(list []feed.ClaudeSession) tea.Cmd {
	if len(list) == 0 {
		return nil
	}
	reader := m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		for _, session := range list {
			if err := reader.StopClaude(ctx, session.Machine, session.ID); err != nil {
				return "", err
			}
		}
		return "", nil
	}, claudeDoneMsg{})
}

// openMoveMenu is "Mover a": directly to the only other machine, else the list.
func (m *Model) openMoveMenu() tea.Cmd {
	session, found := m.selectedSession()
	if !found {
		return nil
	}
	targets := m.moveTargets(session.Machine)
	if len(targets) == 1 {
		return m.moveSession(session.ID, targets[0].machine.Name)
	}
	if len(targets) == 0 {
		return nil
	}
	return m.openTyped(route{screen: screenMove, arg: session.ID}, "")
}

// moveSession moves a session to another machine and opens it there.
func (m *Model) moveSession(id, to string) tea.Cmd {
	for _, target := range m.moveTargets(m.claudeHost) {
		if target.machine.Name == to && !target.eligible() {
			m.say(to+middleDot+target.reason, true)
			return nil
		}
	}
	from, reader := m.claudeHost, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return reader.MoveClaude(ctx, from, id, to)
	}, claudeDoneMsg{host: to, sid: id})
}

// resume resumes a stopped session on its machine, or on another one (a move).
func (m *Model) resume(id, to string) tea.Cmd {
	if to != "" {
		return m.moveSession(id, to)
	}
	host, reader := m.claudeHost, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return reader.ResumeClaude(ctx, host, id)
	}, claudeDoneMsg{host: host, sid: id})
}

// startClaudeNew begins "＋ Nueva" on the viewed machine: the name, then the project.
func (m *Model) startClaudeNew() tea.Cmd {
	machine, found := m.viewedMachine()
	switch {
	case !found:
		m.say(m.cat.Text(i18n.KeySayNoMachines), true)
		return nil
	case !machine.IsReachable():
		m.say(m.cat.Text(i18n.KeySayMachineOff), true)
		return nil
	case !machine.HasClaude:
		m.say(m.cat.Text(i18n.KeyClNoClaude), true)
		return nil
	}
	cmds := []tea.Cmd{m.openTyped(route{screen: screenClaudeNew, arg: machine.Name}, m.namePrefix())}
	m.input.CursorEnd()
	if _, cached := m.projects[machine.Name]; !cached {
		cmds = append(cmds, m.fetchProjects(machine.Name))
	}
	return tea.Batch(cmds...)
}

// createClaude starts the named session in the chosen project and opens it.
func (m *Model) createClaude(project string) tea.Cmd {
	name := strings.TrimSpace(m.input.Value())
	if name == "" {
		m.say(m.cat.Text(i18n.KeyClSayName), true)
		return nil
	}
	host, reader := m.top().arg, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return reader.NewClaude(ctx, host, name, project)
	}, claudeDoneMsg{host: host})
}
