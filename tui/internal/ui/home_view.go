package ui

import (
	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// homeBody is the machine sections with their cards, plus the detail pane on wide screens.
func (m *Model) homeBody(width, height int) block {
	switch {
	case !m.loaded && m.feedErr != "":
		return m.messageBody(m.cat.Text(i18n.KeyFeedFailed)+middleDot+m.feedErr, width, height)
	case !m.loaded:
		return m.messageBody(m.cat.Text(i18n.KeyLoading), width, height)
	case len(m.snap.Machines) == 0:
		return m.emptyBody(width, height)
	}
	layout := m.homeLayout()
	listWidth, detailWidth := m.homeGeometry()
	scroll := clampScroll(m.scroll, len(layout.lines), height)
	list := block{
		lines: fitLines(layout.lines[scroll:min(scroll+height, len(layout.lines))], height),
		hits:  clipped(layout.hits, scroll, height),
	}
	if len(layout.cells) == 0 {
		list.lines[0] = space + space + theme.Faint().Render(m.cat.Text(i18n.KeyNoTerminals))
	}
	if detailWidth == 0 {
		return list
	}
	detail := m.detailPane(detailWidth, height)
	merged := make([]string, height)
	for i := range merged {
		merged[i] = padRight(list.lines[i], listWidth) + space + padRight(detail.lines[i], detailWidth)
	}
	return block{lines: merged, hits: append(list.hits, shifted(detail.hits, listWidth+cardGap, 0)...)}
}

// detailPane is the right-hand pane: the live screen of the selected terminal or a
// summary of the selected machine.
func (m *Model) detailPane(width, height int) block {
	picked, found := m.selectedCell()
	var pane block
	switch {
	case !found:
		pane = block{lines: splitLines(theme.Panel(width).Height(height - detailFrameRows).Render(""))}
	case picked.kind == cellMachine:
		machine, _ := m.snap.FindMachine(picked.host)
		pane = machineSummary(machine, width, height, m.cat)
	default:
		pane = renderDetail(m.detailSpecFor(picked.term, width, height))
	}
	pane.lines = fitLines(pane.lines, height)
	return pane
}

func (m *Model) detailSpecFor(term feed.Terminal, width, height int) detailSpec {
	return detailSpec{
		term: term, screen: m.shots[term.Key()].lines, width: width, height: height,
		now: m.now(), cat: m.cat,
	}
}

// detailBody is the full screen detail of one terminal (narrow screens).
func (m *Model) detailBody(width, height int) block {
	term, found := m.snap.FindTerminal(m.top().arg)
	if !found {
		return m.messageBody(m.cat.Text(i18n.KeyNoTerminals), width, height)
	}
	pane := renderDetail(m.detailSpecFor(term, width, height))
	pane.lines = fitLines(pane.lines, height)
	return pane
}
