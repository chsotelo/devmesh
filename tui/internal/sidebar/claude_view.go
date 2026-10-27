package sidebar

import (
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	wideRowWidth = 40 // from here the one-word state goes on the name line
	hollowDot    = "○"
	backGlyph    = "‹ "
	pickerArrow  = " ▾"
	indent       = 2
	footerMargin = 1
	footerMinGap = 2
	selectedBar  = "▌"
	ruleGlyph    = "─"
)

// actKind is what a tap on a line or a button does.
type actKind int

const (
	actNone actKind = iota
	actPick
	actStop
	actStopIdle
	actMoveTo
	actMoveMenu
	actResume
	actResumeMenu
	actNew
	actTerminals
	actHistory
	actBack
	actPower
	actCreate
	actSay
)

type cact struct {
	kind  actKind
	arg   string
	extra string
}

// cseg is a clickable span of a line, from column from up to (not including) to.
type cseg struct {
	from, to int
	act      cact
}

// cline is one line of the Claude screens. idx >= 0 marks a line of a list row.
type cline struct {
	text string
	idx  int
	act  cact
	segs []cseg
}

// cbtn is a button under the selected row.
type cbtn struct {
	label string
	act   cact
}

// citem is one row of the list.
type citem struct {
	id      string
	dot     string
	title   string
	word    string
	shown   bool
	dim     bool
	actions []cbtn
}

// screen is the lines of a Claude screen: the ones that stay on top, the scrolling body
// (with where each row starts and ends) and the ones that stay at the bottom.
type screen struct {
	head  []cline
	body  []cline
	foot  []cline
	spans [][2]int
}

func plain(text string) cline { return cline{text: text, idx: -1} }

func (m *Model) textWidth(text string) int { return lipgloss.Width(text) }

func (m *Model) fit(text string, width int) string { return ansi.Truncate(text, width, ellipsis) }

// items are the rows of the current mode.
func (m *Model) items() []citem {
	switch m.claude.mode {
	case modeHistory:
		return m.historyItems()
	case modeTargets:
		return m.targetItems()
	case modeNew:
		return m.projectItems()
	case modePower:
		return m.powerItems()
	default:
		return m.sessionItems()
	}
}

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

func (m *Model) sessionItems() []citem {
	items := []citem{}
	for _, session := range m.sessions() {
		item := citem{
			id: session.ID, dot: sessionDot(session.Status), title: session.Name, word: m.sessionWord(session),
			shown: session.Openable() && session.TmuxSession() == m.shown, dim: session.Status == feed.ClaudeIdle,
		}
		if session.ID == m.claude.sel {
			item.actions = m.sessionActions(session)
		}
		items = append(items, item)
	}
	return items
}

// sessionActions are the buttons under the selected session: stop and move.
func (m *Model) sessionActions(session feed.ClaudeSession) []cbtn {
	buttons := []cbtn{{label: m.cat.Text(i18n.KeyClStop), act: cact{kind: actStop, arg: session.ID}}}
	targets := m.targets()
	switch len(targets) {
	case 0:
	case 1:
		buttons = append(buttons, cbtn{label: m.cat.Format(i18n.KeyClMoveTo, targets[0].Machine.Name),
			act: cact{kind: actMoveTo, arg: session.ID, extra: targets[0].Machine.Name}})
	default:
		buttons = append(buttons, cbtn{label: m.cat.Text(i18n.KeyClMoveMenu), act: cact{kind: actMoveMenu, arg: session.ID}})
	}
	return buttons
}

func (m *Model) historyItems() []citem {
	items := []citem{}
	query := m.query()
	for _, past := range m.claude.machine.History {
		if query != "" && !strings.Contains(strings.ToLower(past.Name), query) {
			continue
		}
		items = append(items, citem{id: past.ID, title: past.Name, word: theme.Dim().Render(feed.IdleWord(past.AgeSecs))})
	}
	if at := m.cursorIndex(items); at >= 0 {
		items[at].actions = m.resumeActions(items[at].id)
	}
	return items
}

func (m *Model) resumeActions(id string) []cbtn {
	buttons := []cbtn{{label: m.cat.Text(i18n.KeyClResume), act: cact{kind: actResume, arg: id}}}
	targets := m.targets()
	switch len(targets) {
	case 0:
	case 1:
		buttons = append(buttons, cbtn{label: m.cat.Format(i18n.KeyClResumeOn, targets[0].Machine.Name),
			act: cact{kind: actResume, arg: id, extra: targets[0].Machine.Name}})
	default:
		buttons = append(buttons, cbtn{label: m.cat.Format(i18n.KeyClResumeOn, "▾"), act: cact{kind: actResumeMenu, arg: id}})
	}
	return buttons
}

func (m *Model) hint(target feed.MoveTarget) string {
	if !target.Eligible() {
		return m.reason(target.Why)
	}
	load := m.cat.Format(i18n.KeyClLoad, strconv.Itoa(target.Load))
	if target.Best {
		return m.cat.Text(i18n.KeyClBest) + " · " + load
	}
	return load
}

func (m *Model) targetItems() []citem {
	items := []citem{}
	query := m.query()
	for _, target := range m.targets() {
		if query != "" && !strings.Contains(strings.ToLower(target.Machine.Name), query) {
			continue
		}
		items = append(items, citem{
			id: target.Machine.Name, dot: theme.MachineDot(target.Machine.Color, target.Machine.IsReachable()),
			title: target.Machine.Name, word: theme.Dim().Render(m.hint(target)), dim: !target.Eligible(),
		})
	}
	return items
}

func (m *Model) projectItems() []citem {
	items := []citem{}
	for _, name := range m.claude.projects {
		items = append(items, citem{id: name, title: name, word: theme.Dim().Render(m.cat.Text(i18n.KeyProjectTag))})
	}
	return items
}

// cursorIndex is the row under the cursor (-1 when there are no rows).
func (m *Model) cursorIndex(items []citem) int {
	if len(items) == 0 {
		return -1
	}
	if m.claude.mode == modeClaude {
		for i, item := range items {
			if item.id == m.claude.sel {
				return i
			}
		}
		return 0
	}
	return min(max(m.claude.cur, 0), len(items)-1)
}

// rowLines draws a list row: two lines, the second one carrying the word on narrow lists.
func (m *Model) sessionRowLines(item citem, index int, selected bool) []cline {
	bar, barStyle := space, theme.Faint()
	switch {
	case selected:
		bar, barStyle = selectedBar, theme.Accent()
	case item.shown:
		bar, barStyle = activeBar, theme.Accent()
	}
	nameStyle := theme.Text()
	if item.dim {
		nameStyle = theme.Dim()
	}
	if selected {
		nameStyle = theme.Bold()
	}
	dot := item.dot
	if dot == "" {
		dot = space
	}
	prefix := barStyle.Render(bar) + dot + space
	room := m.width - m.textWidth(prefix) - footerMargin
	first, second := "", ""
	if m.width >= wideRowWidth {
		room -= m.textWidth(item.word) + 1
		name := nameStyle.Render(m.fit(item.title, max(room, 1)))
		gap := max(m.width-m.textWidth(prefix)-m.textWidth(name)-m.textWidth(item.word)-footerMargin, 1)
		first = prefix + name + strings.Repeat(space, gap) + item.word
	} else {
		first = prefix + nameStyle.Render(m.fit(item.title, max(room, 1)))
		second = strings.Repeat(space, m.textWidth(prefix)) + item.word
	}
	return []cline{
		{text: m.paintRow(first, selected), idx: index},
		{text: m.paintRow(second, selected), idx: index},
	}
}

func (m *Model) paintRow(text string, _ bool) string {
	return text + strings.Repeat(space, max(m.width-m.textWidth(text), 0))
}

// buttonLines lays the buttons of a selected row out under it, wrapping at the width.
func (m *Model) buttonLines(buttons []cbtn) []cline {
	lines := []cline{}
	var current []string
	var segs []cseg
	x := indent
	flush := func() {
		if len(current) == 0 {
			return
		}
		lines = append(lines, cline{text: strings.Repeat(space, indent) + strings.Join(current, space), idx: -1, segs: segs})
		current, segs, x = nil, nil, indent
	}
	for _, b := range buttons {
		label := theme.Button().Render(m.fit("["+b.label+"]", max(m.width-indent-footerMargin, 1)))
		width := m.textWidth(label)
		if x+width > m.width-footerMargin {
			flush()
		}
		segs = append(segs, cseg{from: x, to: x + width, act: b.act})
		current = append(current, label)
		x += width + 1
	}
	flush()
	return lines
}
