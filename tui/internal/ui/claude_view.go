package ui

import (
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	sidebarMin     = 36
	sidebarMax     = 46
	sidebarPercent = 34
	tabsHeight     = 2
	footerHeight   = 2
	claudeRowRows  = 2
	tabGap         = 2
	tabUnderline   = "━"
	pickerArrow    = " ▾"
	hollowDot      = "○"
)

// claudeGeometry is how the home sidebar divides its height: the tabs on top, the rows,
// the optional stale line and the footer at the bottom.
type claudeGeometry struct {
	rowsTop  int
	rowsRoom int
	stale    int
}

func claudeGeometryFor(height int, hasStale bool) claudeGeometry {
	stale := 0
	if hasStale {
		stale = 1
	}
	return claudeGeometry{rowsTop: tabsHeight, rowsRoom: max(height-tabsHeight-footerHeight-stale, 0), stale: stale}
}

// visibleRows is how many session rows fit.
func (g claudeGeometry) visibleRows() int { return max(g.rowsRoom/claudeRowRows, 1) }

// claudeSidebarWidth is the width of the sessions list next to the session pane.
func (m *Model) claudeSidebarWidth() int {
	return min(max(m.width*sidebarPercent/100, sidebarMin), sidebarMax)
}

// claudeHomeBody is the sessions of one machine, plus the session pane on wide screens.
func (m *Model) claudeHomeBody(width, height int) block {
	switch {
	case !m.loaded && m.feedErr != "":
		return m.messageBody(m.cat.Text(i18n.KeyFeedFailed)+middleDot+m.feedErr, width, height)
	case !m.loaded:
		return m.messageBody(m.cat.Text(i18n.KeyLoading), width, height)
	case len(m.snap.Machines) == 0:
		return m.emptyBody(width, height)
	}
	if !m.wide() {
		return m.claudeSidebar(width, height)
	}
	listWidth := m.claudeSidebarWidth()
	list := m.claudeSidebar(listWidth, height)
	pane := m.claudePane(width-listWidth-cardGap, height)
	merged := make([]string, height)
	for i := range merged {
		merged[i] = padRight(list.lines[i], listWidth) + space + padRight(pane.lines[i], width-listWidth-cardGap)
	}
	return block{lines: merged, hits: append(list.hits, shifted(pane.hits, listWidth+cardGap, 0)...)}
}

// claudeSidebar is the machine tabs, the session rows, the stale line and the footer.
func (m *Model) claudeSidebar(width, height int) block {
	list := m.sessions()
	stale := feed.StaleSessions(list)
	geometry := claudeGeometryFor(height, len(stale) > 0)
	lines := make([]string, 0, height)
	var hits []hit
	tabLines, tabHits := m.machineTabs(width)
	lines, hits = append(lines, tabLines...), append(hits, tabHits...)
	lines = append(lines, m.sessionRows(list, width, geometry, &hits)...)
	lines = fitLines(lines, height-footerHeight-geometry.stale)
	if len(stale) > 0 {
		lines = append(lines, m.staleLine(len(stale), width))
		hits = append(hits, hit{area: rect{x: 0, y: len(lines) - 1, w: width, h: 1}, act: intent{verb: verbStopIdle}})
	}
	footer, footerHits := m.claudeFooter(width, len(lines))
	lines, hits = append(lines, footer...), append(hits, footerHits...)
	return block{lines: fitLines(lines, height), hits: hits}
}

// machineTabs draws "Mac  laptop" tabs in each machine's color (the chosen one underlined),
// or one "● Mac ▾" picker when there are more machines than tabs.
func (m *Model) machineTabs(width int) ([]string, []hit) {
	current, _ := m.viewedMachine()
	if !m.useTabs() {
		label := theme.MachineDot(current.Color, current.IsReachable()) + space + theme.Bold().Render(current.Name) + theme.Dim().Render(pickerArrow)
		return []string{space + label, ""}, []hit{{area: rect{x: 0, y: 0, w: width, h: tabsHeight}, act: intent{verb: verbPickMachine}}}
	}
	top, underline := space, space
	hits := make([]hit, 0, len(m.snap.Machines))
	x := 1
	for _, machine := range m.snap.Machines {
		on := machine.Name == m.claudeHost
		style := theme.MachineColor(machine.Color).Bold(true)
		if !machine.IsReachable() {
			style = theme.Faint()
		}
		label := style.Render(machine.Name)
		bar := strings.Repeat(space, cellWidth(label))
		if on {
			bar = style.Render(strings.Repeat(tabUnderline, cellWidth(label)))
		}
		top += label + strings.Repeat(space, tabGap)
		underline += bar + strings.Repeat(space, tabGap)
		hits = append(hits, hit{area: rect{x: x, y: 0, w: cellWidth(label) + tabGap, h: tabsHeight}, act: intent{verb: verbViewMachine, arg: machine.Name}})
		x += cellWidth(label) + tabGap
	}
	return []string{padRight(top, width), padRight(underline, width)}, hits
}

// sessionRows draws the visible rows (two lines each, a comfortable touch target) and
// records what a tap on each does. With nothing to list it says why.
func (m *Model) sessionRows(list []feed.ClaudeSession, width int, geometry claudeGeometry, hits *[]hit) []string {
	if len(list) == 0 {
		return []string{theme.Faint().Render(space + space + m.emptyReason())}
	}
	visible := geometry.visibleRows()
	from := min(max(m.claudeScroll, 0), max(len(list)-visible, 0))
	lines := []string{}
	for _, session := range list[from:min(from+visible, len(list))] {
		y := geometry.rowsTop + len(lines)
		lines = append(lines, m.sessionRow(session, width), "")
		*hits = append(*hits, hit{area: rect{x: 0, y: y, w: width, h: claudeRowRows}, act: intent{verb: verbSelect, arg: claudeKey(session.ID)}})
	}
	return lines
}

// emptyReason says why the viewed machine lists no sessions.
func (m *Model) emptyReason() string {
	machine, _ := m.viewedMachine()
	switch {
	case !machine.IsReachable():
		return m.cat.Text(i18n.KeyOfflineHint)
	case !machine.HasClaude && !machine.ClaudeKnown:
		return m.cat.Text(i18n.KeyClOutdated)
	case !machine.HasClaude:
		return m.cat.Text(i18n.KeyClNoClaude)
	default:
		return m.cat.Text(i18n.KeyClNothing)
	}
}

// sessionDot is the state dot: blue when working, orange when it waits, hollow when idle.
func sessionDot(status feed.ClaudeStatus) string {
	switch status {
	case feed.ClaudeWorking:
		return lipgloss.NewStyle().Foreground(lipgloss.Color(theme.ColorWorking)).Render(theme.Dot)
	case feed.ClaudeWaiting:
		return lipgloss.NewStyle().Foreground(lipgloss.Color(theme.ColorWaiting)).Render(theme.Dot)
	default:
		return theme.Faint().Render(hollowDot)
	}
}

// sessionWord is the one word after the name: what it does, or how long it has been idle.
func (m *Model) sessionWord(session feed.ClaudeSession) string {
	switch session.Status {
	case feed.ClaudeWorking:
		return lipgloss.NewStyle().Foreground(lipgloss.Color(theme.ColorWorking)).Render(m.cat.Text(i18n.KeyClWorking))
	case feed.ClaudeWaiting:
		return lipgloss.NewStyle().Foreground(lipgloss.Color(theme.ColorWaiting)).Render(m.cat.Text(i18n.KeyClWaiting))
	default:
		return theme.Dim().Render(feed.IdleWord(session.IdleSecs))
	}
}

// sessionRow is "▌ ● name                trabajando" (the name exactly as the user set it).
func (m *Model) sessionRow(session feed.ClaudeSession, width int) string {
	marker, name := space, theme.Text().Render(session.Name)
	switch {
	case session.ID == m.claudeSel:
		marker, name = theme.Accent().Render(selectionMark), theme.Bold().Render(session.Name)
	case session.Status == feed.ClaudeIdle:
		name = theme.Dim().Render(session.Name)
	}
	return spread(marker+sessionDot(session.Status)+space+name, m.sessionWord(session)+space, width)
}

// staleLine is "3 sin usar hace más de 1 h · Detener las 3"; a tap anywhere on it stops them.
func (m *Model) staleLine(count, width int) string {
	total := strconv.Itoa(count)
	stale, stop := m.cat.Format(i18n.KeyClStale, total), m.cat.Format(i18n.KeyClStopAll, total)
	joined := space + theme.Dim().Render(stale+middleDot) + theme.Accent().Render(stop)
	if cellWidth(joined) <= width {
		return joined
	}
	return spread(space+theme.Dim().Render(stale), theme.Accent().Render(stop)+space, width)
}

// claudeFooter is the rule and the three destinations: new on the left, terminals in the
// middle, history on the right. Each destination owns the space up to the next one.
func (m *Model) claudeFooter(width, row int) ([]string, []hit) {
	machine, _ := m.viewedMachine()
	labels := []string{
		m.cat.Text(i18n.KeyClNew),
		m.cat.Text(i18n.KeyClTerminals),
		m.cat.Format(i18n.KeyClHistory, strconv.Itoa(len(machine.History))),
	}
	acts := []intent{{verb: verbNew}, {verb: verbTerminals}, {verb: verbHistory}}
	last := len(labels) - 1
	starts := make([]int, len(labels))
	starts[0] = barMargin
	starts[last] = max(width-cellWidth(labels[last])-barMargin, starts[0]+cellWidth(labels[0])+1)
	middle := starts[0] + cellWidth(labels[0])
	starts[1] = middle + max((starts[last]-middle-cellWidth(labels[1]))/2, 1)
	var line strings.Builder
	hits := make([]hit, 0, len(labels))
	at := 0
	for i, label := range labels {
		line.WriteString(strings.Repeat(space, max(starts[i]-at, 0)) + theme.Dim().Render(label))
		at = max(starts[i], at) + cellWidth(label)
		from, to := 0, width
		if i > 0 {
			from = starts[i] - 1
		}
		if i < last {
			to = starts[i+1] - 1
		}
		hits = append(hits, hit{area: rect{x: from, y: row, w: max(to-from, 1), h: footerHeight}, act: acts[i]})
	}
	rule := theme.Faint().Render(strings.Repeat(ruleGlyph, width))
	return []string{rule, padRight(line.String(), width)}, hits
}
