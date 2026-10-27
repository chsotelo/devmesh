package sidebar

import (
	"context"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

// The status bar buttons of the open session reach this pane as these keys (dm sends them
// with tmux send-keys when the user taps the ranges of the bar).
const (
	keyHeaderStop = "f8"
	keyHeaderMove = "f9"
	// headerTitleRunes is the longest session title the status bar is told about.
	headerTitleRunes = 40
	// polls that may still report a session other than the one just shown.
	showGrace = 2
)

// openSession is the Claude session the right pane shows.
func (m *Model) openSession() (feed.ClaudeSession, bool) {
	if m.shown == "" {
		return feed.ClaudeSession{}, false
	}
	for _, session := range m.sessions() {
		if session.Openable() && session.TmuxSession() == m.shown {
			return session, true
		}
	}
	return feed.ClaudeSession{}, false
}

// wantedHeader is the header the open session calls for.
func (m *Model) wantedHeader() source.Header {
	session, found := m.openSession()
	if !found {
		return source.Header{}
	}
	want := source.Header{Title: truncateRunes(session.Name, headerTitleRunes), Stop: m.cat.Text(i18n.KeyClStop)}
	targets := m.targets()
	switch len(targets) {
	case 0:
	case 1:
		want.Move = m.cat.Format(i18n.KeyClMoveTo, targets[0].Machine.Name)
	default:
		want.Move = m.cat.Text(i18n.KeyClMoveMenu)
	}
	return want
}

func truncateRunes(text string, limit int) string {
	runes := []rune(text)
	if len(runes) <= limit {
		return text
	}
	return string(runes[:limit-1]) + ellipsis
}

// syncHeader tells the status bar about the open session when it changed.
func (m *Model) syncHeader() tea.Cmd {
	want := m.wantedHeader()
	if want == m.header {
		return nil
	}
	m.header = want
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		_ = src.SetHeader(ctx, host, want) // cosmetic: the next change retries
		return nil
	}
}

// stopOpen is the status bar's Stop: the open session, not the row under the cursor.
func (m *Model) stopOpen() tea.Cmd {
	session, found := m.openSession()
	if !found {
		return nil
	}
	return m.stopSessions([]feed.ClaudeSession{session})
}

// moveOpen is the status bar's Move: straight to the only other machine, else the list.
func (m *Model) moveOpen() tea.Cmd {
	session, found := m.openSession()
	if !found {
		return nil
	}
	return m.moveSession(session)
}

// headerKey runs the key a status bar button sends; ok is false for any other key.
func (m *Model) headerKey(name string) (tea.Cmd, bool) {
	switch name {
	case keyHeaderStop:
		return m.stopOpen(), true
	case keyHeaderMove:
		return m.moveOpen(), true
	}
	return nil, false
}

// claudeShown reports whether the right pane shows a Claude session.
func (m *Model) claudeShown() bool {
	_, found := m.openSession()
	return found
}

// decideClaude keeps the right pane on the Claude home: the open session stays; with none
// open (never opened, stopped, moved away, or a terminal left over from the terminals
// screen) it is a quiet message. A Claude session is never picked on its own.
func (m *Model) decideClaude() tea.Cmd {
	if m.claudeShown() {
		m.held, m.misses = "", 0
		return nil
	}
	if m.shown != "" && indexOf(m.rows, m.shown) < 0 {
		m.misses++
		if m.misses < missesToSwap {
			return nil
		}
	}
	m.resume = ""
	return m.hold(source.HoldChoose)
}
