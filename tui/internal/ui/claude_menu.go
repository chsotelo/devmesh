package ui

import (
	"strconv"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// typedQuery is the lowercase text typed in the input of a list screen.
func (m *Model) typedQuery() string { return strings.ToLower(strings.TrimSpace(m.input.Value())) }

// pickItems is the searchable list of machines to look at.
func (m *Model) pickItems() []menuItem {
	query := m.typedQuery()
	items := []menuItem{}
	for _, machine := range m.snap.Machines {
		if query != "" && !strings.Contains(strings.ToLower(machine.Name), query) {
			continue
		}
		hint := m.cat.Text(i18n.KeyClWhyOff)
		if machine.IsReachable() {
			hint = m.cat.Count(len(machine.Claude), i18n.KeyClSessionsOne, i18n.KeyClSessionsMany)
		}
		items = append(items, menuItem{
			prefix: theme.MachineDot(machine.Color, machine.IsReachable()) + space, label: machine.Name, hint: hint,
			dim: !machine.IsReachable(), act: intent{verb: verbViewMachine, arg: machine.Name},
		})
	}
	return items
}

// targetHint is the right side of a machine row: the reason it cannot receive, or its load
// (marked when it is the best one).
func (m *Model) targetHint(target moveTarget) string {
	if !target.eligible() {
		return target.reason
	}
	load := m.cat.Format(i18n.KeyClLoad, strconv.Itoa(target.load))
	if target.best {
		return m.cat.Text(i18n.KeyClBest) + middleDot + load
	}
	return load
}

// targetItem is a machine row that runs act when the machine can receive, and says why it
// cannot otherwise.
func (m *Model) targetItem(target moveTarget, label string, act intent) menuItem {
	item := menuItem{
		prefix: theme.MachineDot(target.machine.Color, target.machine.IsReachable()) + space,
		label:  label, hint: m.targetHint(target), act: act,
	}
	if !target.eligible() {
		item.dim = true
		item.act = intent{verb: verbSay, arg: target.machine.Name + middleDot + target.reason}
	}
	return item
}

// moveItems is the "Mover a ▾" list for the session in the route.
func (m *Model) moveItems() []menuItem {
	query := m.typedQuery()
	items := []menuItem{}
	for _, target := range m.moveTargets(m.claudeHost) {
		if query != "" && !strings.Contains(strings.ToLower(target.machine.Name), query) {
			continue
		}
		items = append(items, m.targetItem(target, target.machine.Name,
			intent{verb: verbMoveTo, arg: m.top().arg, extra: target.machine.Name}))
	}
	return items
}

// historyItems are the stopped sessions of the viewed machine that match the search.
func (m *Model) historyItems() []menuItem {
	query := m.typedQuery()
	machine, _ := m.viewedMachine()
	items := []menuItem{}
	for _, past := range machine.History {
		if query != "" && !strings.Contains(strings.ToLower(past.Name), query) {
			continue
		}
		items = append(items, menuItem{label: past.Name, hint: feed.IdleWord(past.AgeSecs),
			act: intent{verb: verbHistoryItem, arg: past.ID}})
	}
	return items
}

// historyEntry finds a stopped session of the viewed machine.
func (m *Model) historyEntry(id string) (feed.ClaudeHistory, bool) {
	machine, _ := m.viewedMachine()
	for _, past := range machine.History {
		if past.ID == id {
			return past, true
		}
	}
	return feed.ClaudeHistory{}, false
}

// resumeItems offer to resume a stopped session here or on any other machine.
func (m *Model) resumeItems() []menuItem {
	id := m.top().arg
	items := []menuItem{{label: m.cat.Text(i18n.KeyClResume), act: intent{verb: verbResume, arg: id}}}
	for _, target := range m.moveTargets(m.claudeHost) {
		items = append(items, m.targetItem(target, m.cat.Format(i18n.KeyClResumeOn, target.machine.Name),
			intent{verb: verbResume, arg: id, extra: target.machine.Name}))
	}
	return append(items, m.backItem())
}

// projectChoices are the project folders of the machine of a new session.
func (m *Model) projectChoices() []menuItem {
	items := []menuItem{}
	for _, name := range m.projects[m.top().arg] {
		items = append(items, menuItem{label: name, hint: m.cat.Text(i18n.KeyProjectTag),
			act: intent{verb: verbClaudeCreate, arg: name}})
	}
	return items
}

// claudeTitle is the heading of the Claude list screens.
func (m *Model) claudeTitle() string {
	switch m.top().screen {
	case screenPick:
		return m.cat.Text(i18n.KeyClTitleGoto)
	case screenMove:
		return m.cat.Text(i18n.KeyClTitleMove)
	case screenHistory:
		return m.cat.Format(i18n.KeyClTitleHistory, m.top().arg)
	case screenHistoryItem:
		if past, found := m.historyEntry(m.top().arg); found {
			return past.Name
		}
		return m.cat.Text(i18n.KeyClResume)
	default:
		return m.cat.Format(i18n.KeyClTitleNew, m.top().arg)
	}
}

// claudeNotes are the quiet lines under a Claude list that has nothing to show.
func (m *Model) claudeNotes() []string {
	switch m.top().screen {
	case screenHistory:
		if len(m.menuItems()) == 0 {
			return []string{theme.Faint().Render(space + m.cat.Text(i18n.KeyClHistoryEmpty))}
		}
	case screenClaudeNew:
		if _, cached := m.projects[m.top().arg]; !cached {
			return []string{theme.Faint().Render(space + m.cat.Text(i18n.KeyProjectsLoading))}
		}
		if len(m.menuItems()) == 0 {
			return []string{theme.Faint().Render(space + m.cat.Text(i18n.KeyClNoProjects))}
		}
	}
	return nil
}

// isClaudeList reports whether the screen is one of the Claude list screens.
func isClaudeList(kind screen) bool {
	switch kind {
	case screenPick, screenMove, screenHistory, screenHistoryItem, screenClaudeNew:
		return true
	default:
		return false
	}
}

// claudeItems are the rows of a Claude list screen.
func (m *Model) claudeItems() []menuItem {
	switch m.top().screen {
	case screenPick:
		return m.pickItems()
	case screenMove:
		return m.moveItems()
	case screenHistory:
		return m.historyItems()
	case screenHistoryItem:
		return m.resumeItems()
	case screenClaudeNew:
		return m.projectChoices()
	default:
		return nil
	}
}

// hasTextInput reports whether the screen has the input box (search or name).
func hasTextInput(kind screen) bool {
	return kind == screenPick || kind == screenMove || kind == screenHistory || kind == screenClaudeNew
}

// inputLabel is the title of the input box of a Claude list screen.
func (m *Model) inputLabel() string {
	if m.top().screen == screenClaudeNew {
		return m.cat.Text(i18n.KeyClGhostName)
	}
	return m.cat.Text(i18n.KeyGhostSearch)
}
