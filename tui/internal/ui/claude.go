package ui

import (
	"fmt"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

const (
	maxTabs       = 3
	prefixClaude  = "c:"
	namePrefixSep = " - "
	monthLetters  = 3
)

// claudeKey is the identity of a session on the home list.
func claudeKey(id string) string { return prefixClaude + id }

// viewedMachine is the machine whose sessions the home shows.
func (m *Model) viewedMachine() (feed.Machine, bool) { return m.snap.FindMachine(m.claudeHost) }

// sessions are the live sessions of the viewed machine, in display order.
func (m *Model) sessions() []feed.ClaudeSession {
	machine, found := m.viewedMachine()
	if !found {
		return nil
	}
	return feed.OrderedSessions(machine.Claude)
}

// selectedSession is the session under the cursor of the home list.
func (m *Model) selectedSession() (feed.ClaudeSession, bool) {
	for _, session := range m.sessions() {
		if session.ID == m.claudeSel {
			return session, true
		}
	}
	return feed.ClaudeSession{}, false
}

// claudeTerminal is the tmux window a session runs in, as the feed lists it (the live
// screen is read from there); a bare terminal without a window when the feed lacks it.
func (m *Model) claudeTerminal(session feed.ClaudeSession) feed.Terminal {
	name := session.TmuxSession()
	if machine, found := m.snap.FindMachine(session.Machine); found {
		var first *feed.Terminal
		for i, term := range machine.Terminals {
			switch {
			case term.Session != name:
			case term.Active:
				return term
			case first == nil:
				first = &machine.Terminals[i]
			}
		}
		if first != nil {
			return *first
		}
	}
	return feed.Terminal{Host: session.Machine, Session: name}
}

// defaultClaudeHost is the machine to start on: this device when it is a machine, else the
// first online one that has Claude.
func defaultClaudeHost(snap feed.Snapshot) string {
	if _, found := snap.FindMachine(snap.Device); found {
		return snap.Device
	}
	for _, machine := range snap.Machines {
		if machine.IsReachable() && machine.HasClaude {
			return machine.Name
		}
	}
	if len(snap.Machines) > 0 {
		return snap.Machines[0].Name
	}
	return ""
}

// resolveClaude keeps the viewed machine and the selected session on something that exists.
func (m *Model) resolveClaude() {
	if _, found := m.viewedMachine(); !found {
		m.claudeHost = defaultClaudeHost(m.snap)
	}
	list := m.sessions()
	for _, session := range list {
		if session.ID == m.claudeSel {
			return
		}
	}
	m.claudeSel = ""
	if len(list) > 0 {
		m.claudeSel = list[0].ID
	}
}

// closeVanishedSession leaves the full screen session that was stopped elsewhere.
func (m *Model) closeVanishedSession() {
	if m.top().screen != screenSession {
		return
	}
	for _, session := range m.sessions() {
		if session.ID == m.top().arg {
			return
		}
	}
	m.pop()
}

// useTabs reports whether the machines fit as tabs (few machines) or need a picker.
func (m *Model) useTabs() bool { return len(m.snap.Machines) <= maxTabs }

// moveTarget is a machine a session could move to, with the reason in words.
type moveTarget struct {
	machine feed.Machine
	reason  string
	load    int
	best    bool
}

func (t moveTarget) eligible() bool { return t.reason == "" }

// moveTargets are the other machines in the order of feed.MoveTargets, each reason translated.
func (m *Model) moveTargets(from string) []moveTarget {
	targets := []moveTarget{}
	for _, found := range feed.MoveTargets(m.snap.Machines, from) {
		target := moveTarget{machine: found.Machine, load: found.Load, best: found.Best}
		switch found.Why {
		case feed.WhyOff:
			target.reason = m.cat.Text(i18n.KeyClWhyOff)
		case feed.WhyNoClaude:
			target.reason = m.cat.Text(i18n.KeyClWhyNoClaude)
		case feed.WhyOutdated:
			target.reason = m.cat.Text(i18n.KeyClWhyOutdated)
		}
		targets = append(targets, target)
	}
	return targets
}

// namePrefix is the start of a new session name: today's date in the user's style.
func (m *Model) namePrefix() string {
	today := m.now()
	return fmt.Sprintf("%02d%s", today.Day(), today.Month().String()[:monthLetters]) + namePrefixSep
}
