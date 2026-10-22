package ui

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

// Update is the Bubble Tea update function: it never blocks, slow work runs in commands.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ensureVisible()
		return m, m.refreshShots()
	case tea.KeyMsg:
		return m, m.handleKey(msg)
	case tea.MouseMsg:
		return m, m.handleMouse(msg)
	case feedMsg:
		return m, m.applyFeed(msg)
	case shotMsg:
		m.applyShot(msg)
	case feedTickMsg:
		return m, m.onFeedTick()
	case shotTickMsg:
		return m, tea.Batch(m.refreshShots(), shotTick())
	case projectsMsg:
		m.applyProjects(msg)
	case devicesMsg:
		m.devicesBusy = false
		m.devicesText, m.devicesErr = msg.text, errorText(msg.err)
	case actionMsg:
		return m, m.applyAction(msg)
	case execDoneMsg:
		return m, m.applyExecDone(msg)
	}
	return m, nil
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return feed.Clean(err.Error())
}

// onFeedTick starts a new reading unless the previous one is still running.
func (m *Model) onFeedTick() tea.Cmd {
	if m.feedBusy {
		return feedTick()
	}
	return tea.Batch(m.fetchFeed(), feedTick())
}

// applyFeed takes a reading of the mesh. A reading that answers an older request is dropped.
func (m *Model) applyFeed(msg feedMsg) tea.Cmd {
	if msg.seq != m.feedSeq {
		return nil
	}
	m.feedBusy = false
	if msg.err != nil {
		m.feedErr = errorText(msg.err)
		return nil
	}
	m.snap, m.loaded, m.feedErr = msg.snap, true, ""
	m.pruneShots()
	m.resolveSelection()
	m.ensureVisible()
	m.closeVanishedDetail()
	return m.refreshShots()
}

// pruneShots forgets the screens of terminals that no longer exist.
func (m *Model) pruneShots() {
	for key := range m.shots {
		if _, found := m.snap.FindTerminal(key); !found {
			delete(m.shots, key)
		}
	}
}

// closeVanishedDetail leaves the detail view of a terminal that was closed elsewhere.
func (m *Model) closeVanishedDetail() {
	current := m.top()
	if current.screen != screenDetail {
		return
	}
	if _, found := m.snap.FindTerminal(current.arg); !found {
		m.pop()
	}
}

// applyShot stores a live screen, unless a newer request replaced the one that answered.
func (m *Model) applyShot(msg shotMsg) {
	if m.inflight[msg.key] != msg.id {
		return
	}
	delete(m.inflight, msg.key)
	if msg.err != nil {
		if _, had := m.shots[msg.key]; !had {
			m.shots[msg.key] = shot{lines: []string{m.cat.Text(i18n.KeyPreviewNoScreen)}, at: m.now()}
		}
		return
	}
	m.shots[msg.key] = shot{lines: msg.lines, at: m.now()}
}

func (m *Model) applyProjects(msg projectsMsg) {
	if msg.err != nil {
		m.projects[msg.host] = []string{}
		m.say(m.failure(msg.err), true)
		return
	}
	m.projects[msg.host] = msg.names
}

// applyAction ends a background action: report a failure, then do what it asked for next.
func (m *Model) applyAction(msg actionMsg) tea.Cmd {
	if msg.err != nil {
		m.say(m.failure(msg.err), true)
		return nil
	}
	if msg.goHome {
		m.routes = m.routes[:1]
	}
	cmds := []tea.Cmd{}
	if msg.reload {
		m.notice = ""
		cmds = append(cmds, m.fetchFeed())
	}
	if msg.next != nil {
		cmds = append(cmds, msg.next)
	}
	return tea.Batch(cmds...)
}

// applyExecDone brings the panel back after a full screen command.
func (m *Model) applyExecDone(msg execDoneMsg) tea.Cmd {
	if msg.err != nil {
		m.say(m.failure(msg.err), true)
	}
	if msg.goHome {
		m.routes = m.routes[:1]
	}
	return tea.Batch(m.fetchFeed(), m.refreshShots())
}

// refreshShots reads the live screen of every terminal in view, a few at a time (the
// source limits the concurrency) and only when the last reading is older than half a tick.
func (m *Model) refreshShots() tea.Cmd {
	cmds := []tea.Cmd{}
	for _, term := range m.visibleTerminals() {
		key := term.Key()
		if _, busy := m.inflight[key]; busy {
			continue
		}
		if last, known := m.shots[key]; known && m.now().Sub(last.at) < shotEvery/2 {
			continue
		}
		cmds = append(cmds, m.fetchShot(term))
	}
	return tea.Batch(cmds...)
}

// visibleTerminals are the terminals whose screen is on view: the cards in the viewport,
// the selected one (detail pane) or the one of the detail view.
func (m *Model) visibleTerminals() []feed.Terminal {
	switch m.top().screen {
	case screenDetail:
		if term, found := m.snap.FindTerminal(m.top().arg); found {
			return []feed.Terminal{term}
		}
	case screenHome:
		return m.visibleCards()
	}
	return nil
}

func (m *Model) visibleCards() []feed.Terminal {
	view := m.bodyHeight()
	seen := map[string]bool{}
	terms := []feed.Terminal{}
	for _, c := range m.homeLayout().cells {
		onScreen := c.area.y+c.area.h > m.scroll && c.area.y < m.scroll+view
		if c.kind != cellTerminal || seen[c.term.Key()] || !(onScreen || c.key == m.selected) {
			continue
		}
		seen[c.term.Key()] = true
		terms = append(terms, c.term)
	}
	return terms
}
