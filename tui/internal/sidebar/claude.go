package sidebar

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	meshEvery      = 7 // polls between two readings of the whole mesh (move targets)
	claudeBudget   = 130 * time.Second
	maxInputRunes  = 64
	dayLetters     = 3
	dateSeparator  = " - "
	namePromptMark = "❯ "
)

// mode is what the list shows: the Claude sessions (home), the terminals of the machine,
// the history of stopped sessions, the machines a session can go to, the new session form.
type mode int

const (
	modeClaude mode = iota
	modeTerminals
	modeHistory
	modeTargets
	modeNew
	modePower
)

// pending is the session waiting for a destination in modeTargets.
type pending struct {
	id     string
	resume bool
}

// claudeState is everything the Claude screens need beyond the terminal list.
type claudeState struct {
	mode       mode
	machine    feed.Machine
	mesh       feed.Snapshot
	meshBusy   bool
	polls      int
	sel        string
	cur        int
	top        int
	input      textinput.Model
	pending    pending
	projects   []string
	projectsOK bool
	busy       bool
	polled     bool
	note       string
}

func newClaudeState() claudeState {
	field := textinput.New()
	field.Prompt = namePromptMark
	field.CharLimit = maxInputRunes
	field.PromptStyle = theme.Bold()
	field.TextStyle = theme.Text()
	field.PlaceholderStyle = theme.Faint()
	return claudeState{input: field}
}

// meshMsg carries the reading of the whole mesh.
type meshMsg struct {
	snap feed.Snapshot
	err  error
}

// projectsMsg carries the project folders of this machine.
type projectsMsg struct {
	names []string
	err   error
}

// claudeDoneMsg is the end of an action on a Claude session; to is where a session was
// opened (empty when the action opens nothing).
type claudeDoneMsg struct {
	err  error
	to   string
	sid  string
	open string
}

func (m *Model) meshCmd() tea.Cmd {
	if m.claude.meshBusy {
		return nil
	}
	m.claude.meshBusy = true
	src := m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), pollBudget)
		defer cancel()
		snap, err := src.Feed(ctx)
		return meshMsg{snap: snap, err: err}
	}
}

func (m *Model) projectsCmd() tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		names, err := src.Projects(ctx, host)
		return projectsMsg{names: names, err: err}
	}
}

// sessions are the live Claude sessions of this machine in display order.
func (m *Model) sessions() []feed.ClaudeSession { return feed.OrderedSessions(m.claude.machine.Claude) }

func (m *Model) selectedClaude() (feed.ClaudeSession, bool) {
	for _, session := range m.sessions() {
		if session.ID == m.claude.sel {
			return session, true
		}
	}
	return feed.ClaudeSession{}, false
}

// resolveClaudeSelection keeps the selection on a session that exists: the one in the
// right pane when there is one, else the first.
func (m *Model) resolveClaudeSelection() {
	list := m.sessions()
	for _, session := range list {
		if session.ID == m.claude.sel {
			return
		}
	}
	m.claude.sel = ""
	for _, session := range list {
		if session.Openable() && session.TmuxSession() == m.shown {
			m.claude.sel = session.ID
			return
		}
	}
	if len(list) > 0 {
		m.claude.sel = list[0].ID
	}
}

// windowOf is the tmux window of a session, read from the terminals of the machine.
func (m *Model) windowOf(session feed.ClaudeSession) string {
	for _, row := range m.rows {
		if row.Session == session.TmuxSession() {
			return row.Window
		}
	}
	return ""
}

// keeperSession is the dedicated terminal the workspace lands on.
const keeperSession = "main"

// firstCandidate is the terminal to show when nothing is: the "main" keeper, else the first
// terminal that does not run a Claude session. A Claude session is never picked here: it is
// shown only after an explicit action, because attaching a second tmux client to a session
// the user is working in elsewhere shrinks that terminal.
func (m *Model) firstCandidate() (Row, bool) {
	claude := map[string]bool{}
	for _, session := range m.sessions() {
		if session.Openable() {
			claude[session.TmuxSession()] = true
		}
	}
	var first *Row
	for i, row := range m.rows {
		if claude[row.Session] {
			continue
		}
		if row.Session == keeperSession {
			return row, true
		}
		if first == nil {
			first = &m.rows[i]
		}
	}
	if first == nil {
		return Row{}, false
	}
	return *first, true
}

// targets are the machines a session could move to, from the last reading of the mesh (or
// none while it is unknown).
func (m *Model) targets() []feed.MoveTarget {
	return feed.MoveTargets(m.claude.mesh.Machines, m.host)
}

func (m *Model) reason(why feed.Why) string {
	switch why {
	case feed.WhyOff:
		return m.cat.Text(i18n.KeyClWhyOff)
	case feed.WhyNoClaude:
		return m.cat.Text(i18n.KeyClWhyNoClaude)
	case feed.WhyOutdated:
		return m.cat.Text(i18n.KeyClWhyOutdated)
	default:
		return ""
	}
}

// goMode changes what the list shows and starts at its first row.
func (m *Model) goMode(next mode) tea.Cmd {
	m.power = powerState{}
	m.misses = 0
	m.claude.mode, m.claude.cur, m.claude.top, m.claude.note = next, 0, 0, ""
	m.claude.input.SetValue("")
	m.claude.input.Blur()
	switch next {
	case modeHistory, modeTargets:
		_ = m.claude.input.Focus() // the blink command is not wanted: the cursor stays steady
	case modeNew:
		_ = m.claude.input.Focus()
		m.claude.input.SetValue(m.namePrefix())
		m.claude.input.CursorEnd()
		if !m.claude.projectsOK {
			return m.projectsCmd()
		}
	case modeTerminals, modeClaude:
		// The right pane follows the screen: a terminal on the terminals screen, the
		// message (or the open session) on the Claude home.
		if m.polled() {
			return m.decide()
		}
	}
	return nil
}

// namePrefix is the start of a new session name: today's date in the user's style.
func (m *Model) namePrefix() string {
	today := time.Now()
	return fmt.Sprintf("%02d", today.Day()) + today.Month().String()[:dayLetters] + dateSeparator
}

// typing reports whether the keyboard goes to the input box.
func (m *Model) typing() bool {
	switch m.claude.mode {
	case modeHistory, modeTargets, modeNew:
		return true
	default:
		return false
	}
}

func (m *Model) query() string { return strings.ToLower(strings.TrimSpace(m.claude.input.Value())) }

// runClaude runs an action in the background and shows where the session went.
func (m *Model) runClaude(work func(ctx context.Context) (string, error), done claudeDoneMsg) tea.Cmd {
	if m.claude.busy {
		return nil
	}
	m.claude.busy = true
	m.claude.note = m.cat.Text(i18n.KeyClWait)
	src := m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), claudeBudget)
		defer cancel()
		session, err := work(ctx)
		if err == nil && session != "" {
			done.open = session
			// Focus even on another machine: the session is followed to its window, where
			// Claude may first ask whether to trust the folder.
			err = src.Show(ctx, source.PaneTarget{Host: done.to, Session: session, Focus: true})
		}
		done.err = err
		return done
	}
}

// applyClaudeDone ends an action: report the failure, or go back to the sessions and read
// the machine again.
func (m *Model) applyClaudeDone(msg claudeDoneMsg) tea.Cmd {
	m.claude.busy = false
	m.claude.note = ""
	if msg.err != nil {
		m.err = errorText(msg.err)
		return m.startPoll()
	}
	m.err = ""
	if msg.sid != "" {
		m.claude.sel = msg.sid
	}
	if msg.open != "" && msg.to != m.host {
		m.claude.note = m.cat.Format(i18n.KeyClNowOn, msg.to)
	}
	if msg.open != "" && msg.to == m.host {
		m.shown, m.expect, m.grace = msg.open, msg.open, showGrace
	}
	m.claude.mode, m.claude.cur, m.claude.top = modeClaude, 0, 0
	m.claude.input.Blur()
	return tea.Batch(m.startPoll(), m.meshCmd())
}

func (m *Model) stopSessions(list []feed.ClaudeSession) tea.Cmd {
	if len(list) == 0 {
		return nil
	}
	src := m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		for _, session := range list {
			if err := src.StopClaude(ctx, session.Machine, session.ID); err != nil {
				return "", err
			}
		}
		return "", nil
	}, claudeDoneMsg{to: m.host})
}

func (m *Model) moveTo(id, to string) tea.Cmd {
	for _, target := range m.targets() {
		if target.Machine.Name == to && !target.Eligible() {
			m.err = to + " · " + m.reason(target.Why)
			return nil
		}
	}
	host, src := m.host, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return src.MoveClaude(ctx, host, id, to)
	}, claudeDoneMsg{to: to, sid: id})
}

func (m *Model) resumeClaude(id, to string) tea.Cmd {
	if to != "" && to != m.host {
		return m.moveTo(id, to)
	}
	host, src := m.host, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return src.ResumeClaude(ctx, host, id)
	}, claudeDoneMsg{to: host, sid: id})
}

func (m *Model) createClaude(project string) tea.Cmd {
	name := strings.TrimSpace(m.claude.input.Value())
	if name == "" {
		m.err = m.cat.Text(i18n.KeyClSayName)
		return nil
	}
	host, src := m.host, m.src
	return m.runClaude(func(ctx context.Context) (string, error) {
		return src.NewClaude(ctx, host, name, project)
	}, claudeDoneMsg{to: host})
}

// openTargets starts the choice of a machine for a session (a move or a resume there).
func (m *Model) openTargets(id string, resume bool) tea.Cmd {
	m.claude.pending = pending{id: id, resume: resume}
	return m.goMode(modeTargets)
}

// moveSelected is "Mover a" on the row under the cursor.
func (m *Model) moveSelected() tea.Cmd {
	session, found := m.selectedClaude()
	if !found {
		return nil
	}
	return m.moveSession(session)
}

// moveSession moves a session: straight to the only other machine, else the list.
func (m *Model) moveSession(session feed.ClaudeSession) tea.Cmd {
	targets := m.targets()
	switch len(targets) {
	case 0:
		return nil
	case 1:
		return m.moveTo(session.ID, targets[0].Machine.Name)
	}
	return m.openTargets(session.ID, false)
}

// chooseSession shows a session in the right pane and moves the keyboard there.
func (m *Model) chooseSession(session feed.ClaudeSession) tea.Cmd {
	m.claude.sel = session.ID
	if !session.Openable() {
		m.err = m.cat.Text(i18n.KeyClOutside)
		return nil
	}
	m.shown, m.held, m.misses = session.TmuxSession(), "", 0
	m.expect, m.grace = m.shown, showGrace
	return m.showCmd(Row{Session: session.TmuxSession(), Window: m.windowOf(session)}, true)
}
