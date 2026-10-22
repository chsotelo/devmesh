package ui

import (
	"strconv"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	appName       = "devmesh"
	refreshGlyph  = "↻"
	barMargin     = 1
	titleGap      = 2
	hintSeparator = "  "
)

// shownVersion is the version of the hub client, else the one of this binary.
func (m *Model) shownVersion() string {
	if m.snap.Version != "" {
		return m.snap.Version
	}
	return m.version
}

// crumb is the breadcrumb after the app name.
func (m *Model) crumb() string {
	current := m.top()
	switch current.screen {
	case screenMachine:
		return crumbArrow + current.arg
	case screenDetail:
		return crumbArrow + strings.Join(strings.SplitN(current.arg, "/", 3)[:min(2, strings.Count(current.arg, "/")+1)], crumbArrow)
	case screenNewMachine:
		return crumbArrow + m.cat.Text(i18n.KeyTitleNew)
	case screenNewProject:
		return crumbArrow + m.cat.Format(i18n.KeyTitleNew2, current.arg)
	case screenAdd:
		return crumbArrow + m.cat.Text(i18n.KeyTitleAdd)
	case screenDevices:
		return crumbArrow + m.cat.Text(i18n.KeyActDevices)
	case screenHelp:
		return crumbArrow + m.cat.Text(i18n.KeyTitleHelp)
	default:
		return ""
	}
}

// topButtons are the buttons of the top bar, most important first (the last ones are
// dropped when the screen is narrow).
func (m *Model) topButtons() []button {
	text := m.cat.Text
	return []button{
		{label: text(i18n.KeyWordNew), act: intent{verb: verbNew}},
		{label: refreshGlyph, act: intent{verb: verbRefresh}},
		{label: text(i18n.KeyWordSend), act: intent{verb: verbSend}},
		{label: text(i18n.KeyWordWeb), act: intent{verb: verbWeb}},
		{label: text(i18n.KeyWordFetch), act: intent{verb: verbFetch}},
		{label: text(i18n.KeyWordDevices), act: intent{verb: verbDevices}},
	}
}

// topBar draws "‹ back  devmesh 0.8.1 › laptop        [new] [send] [fetch] [web] [↻]".
func (m *Model) topBar() block {
	left := space
	var hits []hit
	if len(m.routes) > 1 {
		back := backArrow + m.cat.Text(i18n.KeyWordBack)
		hits = append(hits, hit{area: rect{x: barMargin, y: 0, w: cellWidth(back), h: 1}, act: backIntent})
		left += theme.Text().Render(back) + strings.Repeat(space, titleGap)
	}
	left += theme.Bold().Render(appName) + space + theme.Dim().Render(m.shownVersion()) + theme.Dim().Render(m.crumb())
	room := m.width - cellWidth(left) - titleGap - barMargin
	buttons := fitButtons(m.topButtons(), room)
	row, buttonHits := layoutButtons(buttons, m.width-barMargin-buttonsWidth(buttons), 0)
	line := spread(left, row+space, m.width)
	return block{lines: []string{line}, hits: append(hits, buttonHits...)}
}

// hint is one "key label" pair of the hint bar.
type hint struct {
	key   string
	label string
}

// hints are the shortcuts offered on the current screen, most important first.
func (m *Model) hints() []hint {
	text := m.cat.Text
	back := hint{keyEsc, text(i18n.KeyWordBack)}
	help := hint{keyQuestion, text(i18n.KeyWordShortcuts)}
	switch m.top().screen {
	case screenHome:
		return []hint{{keyEnter, text(i18n.KeyHintOpen)}, {"n", text(i18n.KeyWordNew)}, {keySlash, text(i18n.KeyWordFilter)}, help, {"q", text(i18n.KeyWordQuit)}}
	case screenNewProject:
		return []hint{{keyEnter, text(i18n.KeyHintCreate)}, {"↑↓", text(i18n.KeyHintChoose)}, back}
	case screenAdd:
		return []hint{{keyEnter, text(i18n.KeyHintCreate)}, back}
	case screenHelp:
		return []hint{back}
	case screenDetail:
		return []hint{{keyEnter, text(i18n.KeyHintOpen)}, back, help}
	default:
		return []hint{{keyEnter, text(i18n.KeyHintChoose)}, back, help}
	}
}

// hintBar draws the shortcuts right-aligned, dropping the last ones when they do not fit.
func (m *Model) hintBar() string {
	items := m.hints()
	for len(items) > 0 {
		parts := make([]string, 0, len(items))
		for _, item := range items {
			parts = append(parts, theme.Text().Render(item.key)+space+theme.Faint().Render(item.label))
		}
		line := strings.Join(parts, hintSeparator)
		if cellWidth(line) <= m.width-2*barMargin {
			return spread("", line+space, m.width)
		}
		items = items[:len(items)-1]
	}
	return strings.Repeat(space, m.width)
}

// statusLine draws "tablet · 2 machines · 3 terminals · 1 waiting" and the notice. On
// narrow screens the device name and then the machine count are dropped first.
func (m *Model) statusLine() string {
	cat := m.cat
	device := m.snap.Device
	if device == "" {
		device = appName
	}
	parts := []string{
		device,
		cat.Count(len(m.snap.Machines), i18n.KeyMachineOne, i18n.KeyMachineMany),
		cat.Count(m.snap.TerminalCount(), i18n.KeyTerminalOne, i18n.KeyTerminalMany),
	}
	right := ""
	if text, isError := m.activeNotice(); text != "" {
		right = theme.Dim().Render(text)
		if isError {
			right = theme.Error().Render(text)
		}
		right += space
	}
	waiting := ""
	if count := m.snap.Waiting(); count > 0 {
		waiting = theme.Dim().Render(middleDot) + theme.Accent().Render(cat.Format(i18n.KeyWaitingCount, strconv.Itoa(count)))
	}
	room := m.width - cellWidth(right) - 2*barMargin
	for len(parts) > 1 {
		left := theme.Dim().Render(strings.Join(parts, middleDot)) + waiting
		if cellWidth(left) <= room {
			break
		}
		parts = parts[1:]
	}
	return spread(space+theme.Dim().Render(strings.Join(parts, middleDot))+waiting, right, m.width)
}
