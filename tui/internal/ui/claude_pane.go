package ui

import (
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// claudeSessionBody is the full screen session of narrow screens.
func (m *Model) claudeSessionBody(width, height int) block {
	return m.claudePane(width, height)
}

// claudePane is one session: its name and state, the actions (open, stop, move), where it
// runs and the live screen. It is the right pane of wide screens and the whole screen of
// narrow ones.
func (m *Model) claudePane(width, height int) block {
	session, found := m.selectedSession()
	if !found {
		empty := theme.Panel(width).Height(max(height-detailFrameRows, 0)).Render(theme.Faint().Render(m.emptyReason()))
		return block{lines: fitLines(splitLines(empty), height)}
	}
	inner := width - detailPadding
	buttons, buttonHits := wrapButtons(m.paneButtons(session), inner)
	rows := []string{spread(theme.Accent().Bold(true).Render(session.Name), m.sessionWord(session), inner)}
	rows = append(rows, buttons...)
	rows = append(rows, m.paneInfo(session, inner)...)
	room := max(height-detailFrameRows-len(rows), 0)
	rows = append(rows, fitLines(m.paneScreen(session, room, inner), room)...)
	framed := theme.Panel(width).Padding(0, 1).Height(max(height-detailFrameRows, 0)).Render(strings.Join(rows, newline))
	return block{lines: fitLines(splitLines(framed), height), hits: shifted(buttonHits, detailX(), 1+1)}
}

// paneButtons are the actions of the session: open, stop, move.
func (m *Model) paneButtons(session feed.ClaudeSession) []button {
	text := m.cat.Text
	buttons := []button{}
	if session.Openable() {
		buttons = append(buttons, button{label: text(i18n.KeyWordOpen), act: intent{verb: verbOpenClaude, arg: session.ID}})
	}
	buttons = append(buttons, button{label: text(i18n.KeyClStop), act: intent{verb: verbStop, arg: session.ID}})
	others := m.moveTargets(session.Machine)
	switch len(others) {
	case 0:
	case 1:
		buttons = append(buttons, button{label: m.cat.Format(i18n.KeyClMoveTo, others[0].machine.Name),
			act: intent{verb: verbMoveTo, arg: session.ID, extra: others[0].machine.Name}})
	default:
		buttons = append(buttons, button{label: text(i18n.KeyClMoveMenu), act: intent{verb: verbMoveMenu, arg: session.ID}})
	}
	return buttons
}

// paneInfo is the dim line with the machine and folder, and the rule above the screen.
func (m *Model) paneInfo(session feed.ClaudeSession, inner int) []string {
	where := theme.Dim().Render(truncate(session.Machine+middleDot+session.Cwd, inner))
	label := m.cat.Text(i18n.KeyLiveScreen)
	if !session.Openable() {
		label = m.cat.Text(i18n.KeyClOutside)
	}
	rule := theme.Faint().Render(ruleGlyph+space) + theme.Dim().Render(label) +
		theme.Faint().Render(space+strings.Repeat(ruleGlyph, max(inner-cellWidth(label)-3, 0)))
	return []string{where, rule}
}

// paneScreen is the live screen of the tmux window, or the reason there is none.
func (m *Model) paneScreen(session feed.ClaudeSession, room, inner int) []string {
	if !session.Openable() {
		return []string{theme.Dim().Render(m.cat.Text(i18n.KeyClOutsideHint))}
	}
	return thumbLines(m.shots[m.claudeTerminal(session).Key()].lines, room, inner)
}

// wrapButtons lays buttons out in rows that fit width; it returns the rows and the
// clickable areas, with y relative to the first row.
func wrapButtons(buttons []button, width int) ([]string, []hit) {
	rows := []string{}
	var hits []hit
	for start := 0; start < len(buttons); {
		end := start + 1
		for end < len(buttons) && buttonsWidth(buttons[start:end+1]) <= width {
			end++
		}
		line, lineHits := layoutButtons(buttons[start:end], 0, len(rows))
		rows = append(rows, line)
		hits = append(hits, lineHits...)
		start = end
	}
	return rows, hits
}
