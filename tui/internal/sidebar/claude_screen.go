package sidebar

import (
	"strconv"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// listScreen is a list of rows with the buttons of the cursor row under it.
func (m *Model) listScreen(head []cline) screen {
	scr := screen{head: head}
	items := m.items()
	at := m.cursorIndex(items)
	for i, item := range items {
		start := len(scr.body)
		scr.body = append(scr.body, m.sessionRowLines(item, i, i == at)...)
		if i == at {
			scr.body = append(scr.body, m.buttonLines(item.actions)...)
		}
		scr.spans = append(scr.spans, [2]int{start, len(scr.body)})
	}
	return scr
}

func (m *Model) backLine(title string) cline {
	line := plain(theme.Bold().Render(space + backGlyph + m.fit(title, m.width-3)))
	line.act = cact{kind: actBack}
	return line
}

func (m *Model) inputLine() cline {
	return plain(m.fit(m.claude.input.View(), m.width))
}

// claudeScreen builds the screen of the current mode (not the terminal list).
func (m *Model) claudeScreen() screen {
	var scr screen
	switch m.claude.mode {
	case modeHistory:
		scr = m.listScreen([]cline{m.backLine(m.cat.Format(i18n.KeyClTitleHistory, m.host)), m.inputLine(), plain("")})
	case modeTargets:
		scr = m.listScreen([]cline{m.backLine(m.cat.Text(i18n.KeyClTitleMove)), m.inputLine(), plain("")})
	case modeNew:
		scr = m.listScreen([]cline{m.backLine(m.cat.Format(i18n.KeyClTitleNew, m.host)), m.inputLine(), plain("")})
	case modePower:
		scr = m.listScreen(m.powerHead())
	default:
		scr = m.listScreen(nil)
		scr.foot = m.homeFoot()
	}
	if len(scr.body) == 0 {
		scr.body = []cline{plain(theme.Faint().Render(m.fit(space+m.emptyReason(), m.width)))}
	}
	return scr
}

// emptyReason says why the list has no rows.
func (m *Model) emptyReason() string {
	switch {
	case m.claude.mode == modePower:
		return m.powerReason()
	case !m.polled():
		return m.cat.Text(i18n.KeyLoading)
	case !m.online:
		return m.cat.Text(i18n.KeyOffline)
	case m.claude.mode == modeHistory:
		return m.cat.Text(i18n.KeyClHistoryEmpty)
	case m.claude.mode == modeNew && !m.claude.projectsOK:
		return m.cat.Text(i18n.KeyProjectsLoading)
	case m.claude.mode == modeNew:
		return m.cat.Text(i18n.KeyClNoProjects)
	case m.claude.mode == modeTargets:
		return m.cat.Text(i18n.KeyClWhyNoClaude)
	case !m.claude.machine.HasClaude && !m.claude.machine.ClaudeKnown:
		return m.cat.Text(i18n.KeyClOutdated)
	case !m.claude.machine.HasClaude:
		return m.cat.Text(i18n.KeyClNoClaude)
	default:
		return m.cat.Text(i18n.KeyClNothing)
	}
}

// homeFoot is the stale line and the footer: new, terminals, history. When the three do
// not fit side by side (a narrow list) they are stacked, one per line.
func (m *Model) homeFoot() []cline {
	foot := []cline{}
	if stale := feed.StaleSessions(m.sessions()); len(stale) > 0 {
		total := strconv.Itoa(len(stale))
		text := space + theme.Dim().Render(m.cat.Format(i18n.KeyClStale, total)+" · ") + theme.Accent().Render(m.cat.Format(i18n.KeyClStopAll, total))
		if m.textWidth(text) > m.width {
			text = space + theme.Accent().Render(m.cat.Format(i18n.KeyClStopAll, total))
		}
		line := plain(m.fit(text, m.width))
		line.act = cact{kind: actStopIdle}
		foot = append(foot, line)
	}
	foot = append(foot, plain(theme.Faint().Render(strings.Repeat(ruleGlyph, m.width))))
	labels := []string{
		m.cat.Text(i18n.KeyClNew),
		m.cat.Text(i18n.KeyClTerminals),
		m.cat.Format(i18n.KeyClHistory, strconv.Itoa(len(m.claude.machine.History))),
		powerGlyph,
	}
	acts := []cact{{kind: actNew}, {kind: actTerminals}, {kind: actHistory}, {kind: actPower}}
	used := 2 * footerMargin
	for _, label := range labels {
		used += m.textWidth(label)
	}
	if used+footerMinGap*(len(labels)-1) > m.width {
		for i, label := range labels {
			line := plain(space + theme.Dim().Render(m.fit(label, m.width-2)))
			line.act = acts[i]
			foot = append(foot, line)
		}
		return foot
	}
	gap := (m.width - used) / (len(labels) - 1)
	line, x := cline{idx: -1}, 0
	var text strings.Builder
	text.WriteString(strings.Repeat(space, footerMargin))
	x = footerMargin
	for i, label := range labels {
		line.segs = append(line.segs, cseg{from: max(x-gap/2, 0), to: x + m.textWidth(label) + gap/2, act: acts[i]})
		text.WriteString(theme.Dim().Render(label))
		x += m.textWidth(label)
		if i < len(labels)-1 {
			text.WriteString(strings.Repeat(space, gap))
			x += gap
		}
	}
	line.segs[len(line.segs)-1].to = m.width
	line.text = text.String()
	return append(foot, line)
}

// claudeView draws the screen: head, the scrolled body, and the foot at the bottom.
func (m *Model) claudeView() string {
	scr := m.claudeScreen()
	room := m.bodyRoom(scr)
	m.claude.top = m.clampTop(scr, room)
	lines := []string{}
	for _, l := range scr.head {
		lines = append(lines, l.text)
	}
	body := scr.body[m.claude.top:min(m.claude.top+room, len(scr.body))]
	for _, l := range body {
		lines = append(lines, l.text)
	}
	for len(lines) < len(scr.head)+room {
		lines = append(lines, "")
	}
	for _, l := range scr.foot {
		lines = append(lines, l.text)
	}
	lines = append(lines, m.messageLines()...)
	return strings.Join(lines, "\n")
}

// messageLines are the note and the error under the screen.
func (m *Model) messageLines() []string {
	lines := []string{}
	if m.claude.note != "" {
		lines = append(lines, theme.Dim().Render(m.fit(space+m.claude.note, m.width)))
	}
	if m.err != "" {
		lines = append(lines, theme.Error().Render(m.fit(space+m.err, m.width)))
	}
	return lines
}

// bodyRoom is how many body lines fit between the head and the foot.
func (m *Model) bodyRoom(scr screen) int {
	return max(m.height-len(scr.head)-len(scr.foot)-len(m.messageLines()), 1)
}

func (m *Model) clampTop(scr screen, room int) int {
	return min(max(m.claude.top, 0), max(len(scr.body)-room, 0))
}

// keepClaudeVisible scrolls so the cursor row and its buttons are on screen.
func (m *Model) keepClaudeVisible() {
	scr := m.claudeScreen()
	room := m.bodyRoom(scr)
	at := m.cursorIndex(m.items())
	if at >= 0 && at < len(scr.spans) {
		start, end := scr.spans[at][0], scr.spans[at][1]
		if start < m.claude.top {
			m.claude.top = start
		}
		if end > m.claude.top+room {
			m.claude.top = end - room
		}
	}
	m.claude.top = m.clampTop(scr, room)
}

// lineAt finds the line drawn at row y of the Claude screen.
func (m *Model) lineAt(y int) (cline, bool) {
	scr := m.claudeScreen()
	room := m.bodyRoom(scr)
	switch {
	case y < len(scr.head):
		return scr.head[y], true
	case y < len(scr.head)+room:
		at := m.clampTop(scr, room) + y - len(scr.head)
		if at < len(scr.body) {
			return scr.body[at], true
		}
	default:
		at := y - len(scr.head) - room
		if at < len(scr.foot) {
			return scr.foot[at], true
		}
	}
	return cline{}, false
}

func (m *Model) polled() bool { return m.claude.polled }
